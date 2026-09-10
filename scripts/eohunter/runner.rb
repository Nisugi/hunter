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

    def initialize(world:, behaviors:, interval: 0.25, max_consecutive_failures: 5)
      @world = world
      @behaviors = behaviors.sort_by(&:priority)
      @interval = interval
      @max_failures = max_consecutive_failures
      @stopping = false
      @stop_reason = nil
      @consecutive_failures = 0
      @holder = nil
      @on_tick = []
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
      behavior = @behaviors.find { |b| b.wants_control?(@world) }
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

    # Failure watchdog: N failed actions in a row means our model of the
    # world is wrong - halt and let a human (or the task layer) look.
    def track(behavior, result)
      if result.respond_to?(:failed?) && result.failed?
        @consecutive_failures += 1
        if @consecutive_failures >= @max_failures
          Events.emit(:watchdog_tripped, kind: :repeated_failures,
                      behavior: behavior.name, count: @consecutive_failures)
          stop!(:repeated_failures)
        end
      elsif result.respond_to?(:success?) && result.success?
        @consecutive_failures = 0
      end
    end

    def idle = nil
  end
end
