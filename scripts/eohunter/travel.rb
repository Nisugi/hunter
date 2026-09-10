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
# mid-trip is handled between ticks. A trip belongs to the behavior that
# holds control: when the engine hands control to someone else, the
# holder's trip is suspended (go2 killed, the trip kept) and resumes,
# not counted as an attempt, when the holder gets control back; only
# one trip runs go2 at a time. Rules and bigshot line references in
# hunting-engine-plan.md, "Travel".
#
module EO::Engine
  module Travel
    class Trip
      ATTEMPTS = 5 # bigshot goto 6686
      RETRY_DELAY = 1.0
      SCRIPT = 'go2'

      attr_reader :place, :attempts, :status

      # @param place [Integer, String] a room id, "u" uid or map tag (what go2 takes)
      # @param scripts [#start, #running?, #kill] default Lich's Script
      # @param at [#call] (world, place) -> Boolean; default by room id, uid or tag
      # @param unhide [Boolean] send UNHIDE before starting, as go2 does
      # @param retry_delay [Numeric] seconds before the next attempt after
      #   a go2 that ended short (a pathing error exits at once)
      def initialize(place, scripts: nil, at: nil, unhide: true, attempts: ATTEMPTS, retry_delay: RETRY_DELAY, clock: Time)
        @place = place
        @scripts = scripts || EO::Engine::Behaviors::Rest::LichScripts
        @at = at
        @unhide = unhide
        @max = attempts
        @retry_delay = retry_delay
        @clock = clock
        @retry_at = nil
        @attempts = 0
        @started = false
        @status = :pending
      end

      def done? = %i[arrived failed cancelled].include?(@status)

      # nil while underway; a Result when done.
      def tick(world)
        return finished if done?

        if at?(world)
          stop_script
          @status = :arrived
          Travel.release(self)
          Events.emit(:travel_arrived, place: @place, attempts: @attempts)
          return finished
        end

        if @started && !@scripts.running?(SCRIPT)
          @attempts += 1
          @started = false
          if @attempts >= @max
            @status = :failed
            Travel.release(self)
            Events.emit(:travel_failed, place: @place, attempts: @attempts)
            return finished
          end
          @retry_at = @clock.now + @retry_delay
        end

        unless @started
          return nil if @retry_at && @clock.now < @retry_at

          @retry_at = nil
          Travel.claim(self)
          unhide(world) if @unhide && world.me.hidden?
          @scripts.start(SCRIPT, "#{@place} --disable-confirm")
          @started = true
          Events.emit(:travel_started, place: @place, attempt: @attempts + 1)
        end
        nil
      end

      def underway? = @started && !done?

      # The holder lost control: end go2 now, keep the trip. The next
      # tick starts go2 again from wherever we are, not as a new attempt.
      def suspend!
        return unless underway?

        stop_script
        @started = false
        Events.emit(:travel_suspended, place: @place)
      end

      # The engine is stopping or the holder changed its mind.
      def cancel!
        return if done?

        stop_script
        @status = :cancelled
        Travel.release(self)
      end

      private

      def stop_script
        @scripts.kill(SCRIPT) if @started && @scripts.running?(SCRIPT)
      end

      def finished
        case @status
        when :arrived then Actions::Result.new(status: :success, reason: :arrived)
        when :failed then Actions::Result.new(status: :failed, reason: :could_not_reach)
        else Actions::Result.new(status: :failed, reason: :cancelled)
        end
      end

      # Where go2 takes us: a map id, a "u" server uid, or a map tag.
      def at?(world)
        return @at.call(world, @place) if @at

        place = @place.to_s
        case place
        when /\A\d+\z/ then world.room.id == place.to_i
        when /\Au-?(\d+)\z/i then world.room.uid.to_s == Regexp.last_match(1)
        else world.room.tags.include?(place)
        end
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
    # @return [Symbol] :arrived, :underway, :failed (one blocking attempt
    #   that did not arrive), or :could_not_reach (a Trip's attempts spent)
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
      return :arrived if result.success?

      result.reason == :could_not_reach ? :could_not_reach : :failed
    end

    # Cancel a holder's trip, if any (the engine's stop).
    def self.cancel(holder)
      trip = holder.instance_variable_get(:@trip)
      trip&.cancel! if trip.respond_to?(:cancel!)
      holder.instance_variable_set(:@trip, nil)
    end

    # Suspend a holder's trip, if any (the engine handed control to
    # another behavior). The trip stays on the holder and resumes when
    # its next step is taken.
    def self.suspend(holder)
      trip = holder.instance_variable_get(:@trip)
      trip.suspend! if trip.respond_to?(:suspend!)
    end

    # --- ownership: one go2 at a time --------------------------------------

    # The trip whose go2 is running, if any.
    def self.active = @active

    # A trip about to start go2 takes the script from any other trip
    # still underway (a preempted holder's, suspended late).
    def self.claim(trip)
      @active.suspend! if @active && !@active.equal?(trip) && @active.respond_to?(:suspend!)
      @active = trip
    end

    def self.release(trip)
      @active = nil if @active.equal?(trip)
    end

    # Specs and a fresh run.
    def self.reset! = @active = nil
  end
end
