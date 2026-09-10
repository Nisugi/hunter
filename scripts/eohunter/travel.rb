# frozen_string_literal: true

# ============================================================================
# travel (bigshot's goto and go2, supervised a tick at a time)
# ============================================================================

#
# bigshot's goto (6681) runs the go2 script up to five times and blocks
# until it ends; go2 (6673) unhides first and skips the trip when already
# there. libeo's EO.go2 is that call, and Rest and Wander used it as a
# blocking step: pause and stop could not land during a trip, and an
# escape room or a death mid-trip went unseen until go2 gave up. The
# engine's Trip starts the same go2 script and watches it one tick at a
# time: arrival by room, a script that ended short as one failed attempt,
# five attempts as could_not_reach, and cancel! for the engine's stop.
# Survival outranks whoever holds the trip, so an escape room or a death
# mid-trip is handled between ticks. Rules and bigshot line references
# in hunting-engine-plan.md, "Travel".
#
module EO::Engine
  module Travel
    class Trip
      ATTEMPTS = 5 # bigshot goto 6686
      SCRIPT = 'go2'

      attr_reader :place, :attempts, :status

      # @param place [Integer, String] a room id, "u" uid or map tag (what go2 takes)
      # @param scripts [#start, #running?, #kill] default Lich's Script
      # @param at [#call] (world, place) -> Boolean; default by room id, else EO.at?
      # @param unhide [Boolean] send UNHIDE before starting, as go2 does
      def initialize(place, scripts: nil, at: nil, unhide: true, attempts: ATTEMPTS)
        @place = place
        @scripts = scripts || EO::Engine::Behaviors::Rest::LichScripts
        @at = at
        @unhide = unhide
        @max = attempts
        @attempts = 0
        @started = false
        @status = :pending
      end

      def done? = %i[arrived failed cancelled].include?(@status)

      # nil while underway; a Result when done.
      def tick(world)
        return finished if done?

        if at?(world)
          @scripts.kill(SCRIPT) if @started && @scripts.running?(SCRIPT)
          @status = :arrived
          Events.emit(:travel_arrived, place: @place, attempts: @attempts)
          return finished
        end

        if @started && !@scripts.running?(SCRIPT)
          @attempts += 1
          @started = false
          if @attempts >= @max
            @status = :failed
            Events.emit(:travel_failed, place: @place, attempts: @attempts)
            return finished
          end
        end

        unless @started
          unhide(world) if @unhide && world.me.hidden?
          @scripts.start(SCRIPT, "#{@place} --disable-confirm")
          @started = true
          Events.emit(:travel_started, place: @place, attempt: @attempts + 1)
        end
        nil
      end

      # The engine is stopping or the holder changed its mind.
      def cancel!
        return if done?

        @scripts.kill(SCRIPT) if @started && @scripts.running?(SCRIPT)
        @status = :cancelled
      end

      private

      def finished
        case @status
        when :arrived then Actions::Result.new(status: :success, reason: :arrived)
        when :failed then Actions::Result.new(status: :failed, reason: :could_not_reach)
        else Actions::Result.new(status: :failed, reason: :cancelled)
        end
      end

      def at?(world)
        return @at.call(world, @place) if @at
        return world.room.id == @place.to_i if @place.is_a?(Integer) || @place.to_s =~ /\A\d+\z/

        ::EO.at?(@place)
      rescue StandardError
        false
      end

      def unhide(world)
        Actions::Command.new(world, command: 'unhide').call
      end
    end

    # The travel seam Rest and Wander take: a callable of (room) that
    # answers a Trip to tick, or, for the old blocking style and for
    # specs, true/false. +Travel.step+ drives either one.
    def self.default = ->(room) { Trip.new(room) }

    # @param holder [Object] the behavior; keeps its trip in @trip
    # @return [Symbol] :arrived, :failed, :underway
    def self.step(holder, travel, room, world)
      trip = holder.instance_variable_get(:@trip)
      trip ||= travel.call(room)
      unless trip.respond_to?(:tick)
        holder.instance_variable_set(:@trip, nil)
        return trip ? :arrived : :failed
      end

      holder.instance_variable_set(:@trip, trip)
      result = trip.tick(world)
      return :underway if result.nil?

      holder.instance_variable_set(:@trip, nil)
      result.success? ? :arrived : :failed
    end

    # Cancel a holder's trip, if any (the engine's stop).
    def self.cancel(holder)
      trip = holder.instance_variable_get(:@trip)
      trip&.cancel! if trip.respond_to?(:cancel!)
      holder.instance_variable_set(:@trip, nil)
    end
  end
end
