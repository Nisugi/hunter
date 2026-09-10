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
      if @paused
        sleep(@interval) unless @stopping
        return
      end

      behavior = @behaviors.find { |b| b.wants_control?(@world) }
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
