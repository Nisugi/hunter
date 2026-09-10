# frozen_string_literal: true

# ============================================================================
# engine (from forge engine.rb)
# ============================================================================

#
# EO::Engine::Engine - the tick loop and priority arbiter.
#
# Each tick: run watchdogs, pick the highest-priority behavior that wants
# control, let it issue one verified action. Intent is re-derived from
# World every tick. The engine prefers halting cleanly (stop! with reason)
# to grinding on a confused state.
#
module EO::Engine
  class Engine
    attr_reader :stop_reason

    # last_evaluations: the arbiter view of the last tick, [[name, wanted]]
    # in priority order down to the behavior that took control (the ones
    # below it were not asked). Answers "why is it resting instead of
    # fighting" from the status line or a watchdog trip.
    attr_reader :last_evaluations

    def initialize(world:, behaviors:, interval: 0.25, max_consecutive_failures: 5, clock: -> { Time.now })
      @world = world
      @behaviors = behaviors.sort_by(&:priority)
      @interval = interval
      @max_failures = max_consecutive_failures
      @clock = clock
      @stopping = false
      @stop_reason = nil
      @consecutive_failures = 0
      @fires = Hash.new { |h, k| h[k] = [] }
      @last_evaluations = []
      @holder = nil
      @on_tick = []
    end

    # Fires inside each budgeted behavior's window right now, {name => count}.
    def fire_counts(now = @clock.call)
      @behaviors.each_with_object({}) do |b, out|
        _limit, window = budget_of(b)
        next if window.nil?

        out[b.name] = @fires[b.name].count { |t| now - t <= window }
      end
    end

    # A block run at the start of every tick, paused or not: the group
    # heartbeat and the follower's report live here.
    def on_tick(&block)
      @on_tick << block
      block
    end

    def stop!(reason)
      @stopping = true
      @stop_reason ||= reason
      # A trip in flight (Rest, Wander) is a go2 script to kill.
      @behaviors.each { |b| b.cancel! if b.respond_to?(:cancel!) }
    end

    def stopping? = @stopping

    # Hold in place without tearing down the session; resume! continues.
    def pause!  = @paused = true
    def resume! = @paused = false
    def paused? = !!@paused

    def run
      Events.emit(:engine_started, behaviors: @behaviors.map(&:name))
      tick until @stopping
      Events.emit(:engine_stopped, reason: @stop_reason)
      @stop_reason
    end

    def tick
      @on_tick.each { |b| b.call(@world) }
      # A callback may have stopped the engine (a lost leader, a lost
      # member, the rescued child): nothing acts after that.
      return if @stopping

      if @paused
        hand_off(nil)
        sleep(@interval)
        return
      end

      note_room
      behavior = choose
      hand_off(behavior)
      if behavior
        result = behavior.tick(@world)
        track(behavior, result)
      else
        idle
      end
      sleep(@interval) unless @stopping
    rescue StandardError => e
      # Carry the backtrace: an engine_error that reports only a reason
      # ends the run with nothing to debug from. Forge frames only - the
      # Lich/gem frames below them are never where the bug is.
      frames = Array(e.backtrace).select { |f| f =~ %r{eohunter}i }.first(8)
      Events.emit(:engine_error, error: e.class.name, message: e.message,
                                 backtrace: frames.empty? ? Array(e.backtrace).first(8) : frames)
      stop!(:engine_error)
    end

    private

    # The room transition, seen here before any behavior is chosen, so
    # the room-scoped state (Engage's (room) commands, Loot's looted
    # list, Survival's flags) resets even when a fight is already waiting
    # in the new room and a follower never wanders.
    def note_room
      id = @world.room.id
      return if id == @room_id

      @room_id = id
      Events.emit(:entered_room, room: id)
    end

    # Control changed hands: the behavior that had it last is told, so a
    # trip it has in flight (Rest, Wander) stops moving us while someone
    # else is issuing commands. Also on pause and on idle.
    def hand_off(behavior)
      return if @holder.equal?(behavior)

      previous = @holder
      @holder = behavior
      return unless previous.respond_to?(:preempted!)

      previous.preempted!(@world)
      Events.emit(:preempted, from: previous.name, to: behavior&.name)
    end

    # The arbiter walk: highest priority first, stopping at the first
    # behavior that wants control. Each guard runs once; the behaviors
    # below the chosen one are not asked, so the trace holds only what
    # was actually evaluated this tick.
    def choose
      @last_evaluations = []
      @behaviors.each do |b|
        wanted = b.wants_control?(@world)
        @last_evaluations << [b.name, wanted]
        return b if wanted
      end
      nil
    end

    # Two watchdogs; either trip halts, and a human (or the task layer)
    # looks. Repeated failures: N failed actions in a row means our model
    # of the world is wrong. Fire budget: more acted ticks in a window
    # than roundtime allows means the behavior is looping on successes
    # (a retarget probe, a re-search) with nothing slowing it down.
    def track(behavior, result)
      if result.respond_to?(:failed?) && result.failed?
        @consecutive_failures += 1
        if @consecutive_failures >= @max_failures
          trip(:repeated_failures, behavior, @consecutive_failures)
          return
        end
      elsif result.respond_to?(:success?) && result.success?
        @consecutive_failures = 0
      end
      count_fire(behavior, result)
    end

    def count_fire(behavior, result)
      limit, window = budget_of(behavior)
      return if limit.nil? || window.nil?
      return unless result.respond_to?(:success?) && (result.success? || result.failed?)

      now = @clock.call
      fires = @fires[behavior.name]
      fires << now
      fires.shift while now - fires.first > window
      trip(:fire_budget, behavior, fires.size) if fires.size > limit
    end

    def trip(kind, behavior, count)
      Events.emit(:watchdog_tripped, kind: kind, behavior: behavior.name, count: count,
                                     evaluations: @last_evaluations.dup)
      stop!(kind)
    end

    def budget_of(behavior)
      return nil unless behavior.respond_to?(:fire_budget)

      behavior.fire_budget
    end

    def idle = nil
  end
end
