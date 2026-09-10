# frozen_string_literal: true

# ============================================================================
# actions (Base: bigshot send ladder and confirmation shapes)
# ============================================================================

#
# EO::Engine::Actions - verified game-command primitives.
#
# Contract: every action returns a Result the caller must handle. An action
# is preconditions -> settle RT -> target still live -> send through the
# refusal ladder -> confirmation (a result line, an observed World change,
# or an awaited bus event) -> Result. No bare fput-and-hope anywhere else.
#
# The ladder is Lich's fput with its bounds (lich-5 #1587: a resend cap,
# a deadline, the engine's interrupt on every wait, named failures); the
# three confirmation shapes are bigshot's cmd_* routines (see
# hunting-engine-plan.md, "Send and confirm").
#
module EO::Engine
  module Actions
    Result = Struct.new(:status, :event, :reason, :line, keyword_init: true) do
      def success? = status == :success
      def failed?  = !success?
    end

    # Mixed into the actions that CAST or SWING - the only ones soft cast
    # roundtime actually blocks. Everything else inherits Base's hard-RT
    # -only wait (see Base#settle_rt for the full rule).
    module CombatRt
      private

      def wait_cast_rt? = true
    end

    class Base
      DEFAULT_TIMEOUT = 8
      RT_SETTLE_CAP = 15

      # The refusal ladder is Lich's fput (lich-5 #1587), bounded: a resend
      # cap, a deadline, the engine's interrupt on every wait, and a named
      # failure instead of false. bigshot's bs_put resends a transient
      # refusal after a quarter second; fput does that under the cap with
      # resend_transient.
      MAX_RESENDS = 5
      SEND_DEADLINE = 30

      # @param world [World]
      # @param interrupt [#call, nil] answers true when the engine is stopping;
      #   every wait inside the action checks it
      def initialize(world, interrupt: nil, **opts)
        @world = world
        @interrupt = interrupt
        @opts = opts
      end

      def call
        pre = preconditions
        return Result.new(status: :failed, reason: pre) unless pre == :ok

        settle_rt
        # settle_rt just slept out a roundtime - seconds during which the
        # target may have died. bigshot re-checks status and GameObj.targets
        # before every command and between array steps; the wait is when
        # kills land.
        return Result.new(status: :failed, reason: :target_gone) unless target_still_live?
        # ...and seconds during which WE may have died.
        return Result.new(status: :failed, reason: :dead) if me.dead?
        return Result.new(status: :failed, reason: :interrupted) if interrupted?

        perform
      end

      private

      def me = @world.me

      def interrupted? = @interrupt ? @interrupt.call ? true : false : false

      # --- the send seam --------------------------------------------------

      # Lich's fput with the bounds (stubbed in specs): the first
      # non-refusal line, left in the script's buffer, or a Symbol naming
      # the failure.
      def game_send(command)
        fput(command, max_resends: MAX_RESENDS, timeout: SEND_DEADLINE, interrupt: @interrupt,
                      resend_transient: true, failures: :symbol)
      end

      # One line from the script's queue, or nil when none is waiting.
      def next_line
        get?
      end

      # Hand a line back so a later reader sees it.
      def unread_line(line)
        script = ::Script.current
        script.downstream_buffer.unshift(line) if script
      end

      # Send +command+ through fput's refusal ladder. Returns the answer
      # line (still in the queue for the confirmation step), or a failed
      # Result: :dead, :interrupted, :too_many_resends, :no_response.
      def send_through_ladder(command)
        answer = game_send(command)
        return Result.new(status: :failed, reason: answer) if answer.is_a?(Symbol)
        return Result.new(status: :failed, reason: :no_response) unless answer.is_a?(String)

        answer
      end

      # --- roundtime -----------------------------------------------------

      # HARD roundtime blocks everything, so it is the only thing every
      # action waits on. CAST (soft) roundtime bars casting, attacking and
      # dropping to defensive; everything else is legal during it, so only
      # the actions that genuinely cannot proceed opt in via CombatRt.
      # bigshot waits both before every command except hide and cock;
      # this is the same exception, generalised. Each wait is capped at
      # RT_SETTLE_CAP and ends on the engine's interrupt.
      def settle_rt
        game_wait_rt(:hard)
        game_wait_rt(:cast) if wait_cast_rt?
      end

      def wait_cast_rt? = false

      # Lich's waitrt? / waitcastrt? (lich-5 #1587): sliced, interruptible,
      # capped. Stubbed in specs.
      def game_wait_rt(kind)
        if kind == :cast
          waitcastrt?(interrupt: @interrupt, cap: RT_SETTLE_CAP)
        else
          waitrt?(interrupt: @interrupt, cap: RT_SETTLE_CAP)
        end
      end

      # --- target --------------------------------------------------------

      # True unless this action aims at a creature that is no longer a live
      # target. GameObj.targets is the game's own filtered list - hostile,
      # alive, with severed limbs and animated noise already excluded - so
      # membership is the whole test. Actions with no target are never
      # blocked by this.
      def target_still_live?
        target = @opts[:target]
        return true if target.nil?

        id = target.respond_to?(:id) ? target.id : target
        return true if id.to_s.empty?

        ids = live_target_ids
        return true if ids.nil? # no target list available - do not block

        ids.include?(id.to_s)
      end

      # nil means "cannot tell", which must never be confused with "the
      # list is empty, so the target is dead".
      def live_target_ids
        return nil unless defined?(::GameObj)

        Array(::GameObj.targets).map { |t| t.id.to_s }
      rescue StandardError
        nil
      end

      def clock_now = Time.now

      # --- confirmation, three shapes -------------------------------------

      # bigshot's cmd_* shape: send, then read lines until one matches
      # +regex+ (every known answer to this command, refusals included) or
      # +timeout+ passes. The matched line is the Result's +line+; the
      # caller decides what it means. No match is :timeout, which bigshot
      # turns into a rest reason and the engine's watchdog counts.
      def send_and_match(command, regex, timeout: DEFAULT_TIMEOUT)
        first = send_through_ladder(command)
        return first if first.is_a?(Result)

        deadline = clock_now + timeout
        until clock_now > deadline
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          return Result.new(status: :failed, reason: :dead) if me.dead?

          line = next_line
          if line.nil?
            sleep 0.05
            next
          end
          return Result.new(status: :success, line: line) if line =~ regex
        end
        Result.new(status: :timeout, reason: :no_confirmation)
      end

      # bigshot's stand / change_stance / wield shape: send, then poll World
      # until the block is true.
      def send_and_observe(command, timeout: DEFAULT_TIMEOUT)
        first = send_through_ladder(command)
        return first if first.is_a?(Result)

        deadline = clock_now + timeout
        until clock_now > deadline
          return Result.new(status: :success) if yield
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          return Result.new(status: :failed, reason: :dead) if me.dead?

          sleep 0.05
        end
        Result.new(status: :timeout, reason: :state_unchanged)
      end

      # The event shape: register the watch, send, wait for a matching bus
      # event. Combat facts arrive from Lich's Combat::Observers via the
      # bus; the ladder has already consumed any roundtime refusal.
      def send_and_await(command, *types, timeout: DEFAULT_TIMEOUT, matcher: nil)
        first = nil
        event = Events.during(types, timeout: timeout, matcher: matcher) do
          first = send_through_ladder(command)
        end
        return first if first.is_a?(Result)
        return Result.new(status: :failed, reason: :dead) if me.dead?

        event ? Result.new(status: :success, event: event) : Result.new(status: :timeout, reason: :no_confirmation)
      end

      # Only a resolution that can plausibly be OURS confirms our action:
      # not a creature's attack on us, not creature-vs-creature, and when
      # the event names a subject and we hold a target, they must agree.
      def confirms_ours(target)
        lambda do |event|
          direction = event.data[:direction]
          next false if %i[incoming third_party].include?(direction)

          subject_id = event.data.dig(:subject, :id)
          next true if subject_id.nil? || target.nil?

          subject_id.to_s == target.id.to_s
        end
      end
    end
  end
end
