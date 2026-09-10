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
# The ladder and the three confirmation shapes are bigshot's (bs_put and
# the cmd_* routines; see hunting-engine-plan.md, "Send and confirm"),
# with the bounds bigshot lacks: a resend cap, a deadline, and an
# interrupt check on every wait so the engine's stop! ends a stuck send.
#
module EO::Engine
  module Actions
    Result = Struct.new(:status, :event, :reason, :line, keyword_init: true) do
      def success? = status == :success
      def skipped? = status == :skipped
      def failed?  = status == :failed || status == :timeout
    end

    # Mixed into the actions that CAST or SWING - the only ones soft cast
    # roundtime actually blocks. Everything else inherits Base's hard-RT
    # -only wait (see Base#settle_rt for the full rule).
    module CombatRt
      private

      def blocked_by_rt? = me.in_rt? || me.in_cast_rt?
    end

    class Base
      DEFAULT_TIMEOUT = 8
      RT_SETTLE_CAP = 15

      # The send ladder's bounds. bigshot's bs_put has none: a "stand"
      # refusal or a "don't seem" answer can loop forever.
      MAX_RESENDS = 5
      SEND_DEADLINE = 30
      # bigshot sleeps N-1 on "...wait N"; Lich's fput sleeps N. N is the
      # game's own number and a second early just earns another refusal.
      RT_REFUSED   = /(?:\.\.\.wait |Wait )(?<seconds>[0-9]+)/
      STAND_FIRST  = /^You.+struggle.+stand/
      # "can't seem" excludes "You rummage ... can't seem to find" the way
      # fput does: that is an answer, not a refusal.
      TRANSIENT    = /stunned|can't do that while|cannot seem|^(?!You rummage).*can't seem|don't seem|Sorry, you may only type ahead/
      STAND_COMMAND = 'stand'

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

      # Fire a command with no reading at all (::put, lib/global_defs.rb).
      # Stubbed in specs.
      def game_put(command)
        put(command)
      end

      # Empty the script's line queue so the next read is the answer to
      # OUR command. bigshot and fput both clear before every send.
      def clear_lines
        clear
      end

      # One line from the script's queue, or nil when none is waiting.
      def next_line
        get?
      end

      # Hand a line back so a later reader sees it. bigshot unshifts the
      # first non-refusal line back onto the buffer before returning it.
      def unread_line(line)
        script = ::Script.current
        script.downstream_buffer.unshift(line) if script
      end

      def stunned? = me.respond_to?(:stunned?) ? me.stunned? : false
      def webbed?  = me.respond_to?(:webbed?) ? me.webbed? : false

      # Send +command+ and climb bigshot's refusal ladder until the game
      # answers with something that is not a refusal. Returns that line
      # (left in the queue for the confirmation step), or a failed Result:
      # :dead, :interrupted, :too_many_resends, :no_response.
      #
      # Every rung is bs_put's. What is new is that each is bounded.
      def send_through_ladder(command)
        deadline = clock_now + SEND_DEADLINE
        resends = 0
        clear_lines
        game_put(command)
        loop do
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          return Result.new(status: :failed, reason: :no_response) if clock_now > deadline

          line = next_line
          if line.nil?
            sleep 0.05
            next
          end

          if line =~ RT_REFUSED
            seconds = Regexp.last_match[:seconds].to_i
            return Result.new(status: :failed, reason: :too_many_resends, line: line) if (resends += 1) > MAX_RESENDS

            wait_interruptible(seconds)
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            clear_lines
            game_put(command)
          elsif line =~ STAND_FIRST
            return Result.new(status: :failed, reason: :too_many_resends, line: line) if (resends += 1) > MAX_RESENDS

            stand_result = send_through_ladder(STAND_COMMAND)
            return stand_result if stand_result.is_a?(Result)

            clear_lines
            game_put(command)
          elsif line =~ TRANSIENT
            return Result.new(status: :failed, reason: :dead, line: line) if me.dead?
            return Result.new(status: :failed, reason: :too_many_resends, line: line) if (resends += 1) > MAX_RESENDS

            if stunned?
              wait_while(deadline) { stunned? }
            elsif webbed?
              wait_while(deadline) { webbed? }
            else
              # bigshot resends after 0.25s; fput gives up here. The resend
              # cap makes bigshot's choice safe.
              sleep 0.25
            end
            return Result.new(status: :failed, reason: :interrupted) if interrupted?
            return Result.new(status: :failed, reason: :dead) if me.dead?

            clear_lines
            game_put(command)
          else
            unread_line(line)
            return line
          end
        end
      end

      # sleep +seconds+ in slices, stopping early on interrupt.
      def wait_interruptible(seconds)
        stop_at = clock_now + seconds
        while clock_now < stop_at
          return if interrupted?

          sleep 0.1
        end
      end

      def wait_while(deadline)
        while yield
          return if interrupted? || clock_now > deadline || me.dead?

          sleep 0.25
        end
      end

      # --- roundtime -----------------------------------------------------

      # HARD roundtime blocks everything, so it is the only thing every
      # action waits on. CAST (soft) roundtime bars casting, attacking and
      # dropping to defensive; everything else is legal during it, so only
      # the actions that genuinely cannot proceed opt in via CombatRt.
      # bigshot waits both before every command except hide and cock;
      # this is the same exception, generalised.
      def settle_rt
        deadline = clock_now + RT_SETTLE_CAP
        while blocked_by_rt? && !me.dead? && clock_now < deadline
          return if interrupted?

          sleep 0.1
        end
      end

      def blocked_by_rt? = me.in_rt?

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
