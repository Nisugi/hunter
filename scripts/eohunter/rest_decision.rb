# frozen_string_literal: true

module EO::Engine::Rest
  # Monotonic time for recovery intervals; never a wall-clock timestamp.
  module Clock
    # @return [Float] elapsed local monotonic seconds
    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Settles transient weight from loot handoffs without sleeping the engine.
  # Field/Town Rest requirement: only observed persistent weight requests rest.
  class Encumbrance
    # @param seconds [Numeric] required overweight interval; zero is immediate
    # @param clock [#now] monotonic clock, replaceable in specs
    def initialize(seconds: 5, clock: Clock)
      @seconds = Float(seconds)
      raise ArgumentError, 'encumbrance grace must be finite and nonnegative' unless @seconds.finite? && @seconds >= 0

      @clock = clock
      @since = nil
    end

    # Loot owns its transaction. Start a fresh grace window after it releases.
    # A below-threshold observation cancels the pending overweight decision.
    # @param percent [Numeric] current encumbrance
    # @param threshold [Numeric] configured rest threshold
    # @param looting [Boolean] owned loot work still in progress
    # @return [Boolean] observed overweight long enough
    def ready?(percent, threshold:, looting: false)
      if looting || percent < threshold
        @since = nil
        return false
      end
      now = @clock.now
      @since ||= now
      now - @since >= @seconds
    end
  end

  # Two optional rest destinations over the existing Rest lifecycle.
  # Field/Town Rest requirement: service needs outrank routine recovery.
  class Sites
    # Stable reason keys used by field_rest_for; display strings stay legacy.
    REASONS = {
      'fried' => 'fried.', 'mana' => 'out of mana.', 'wounded' => 'wounded.',
      'creeping_dread' => 'creeping dread limit.', 'crushing_dread' => 'crushing dread limit.',
      'poison' => 'wall of thorns poison.', 'confusion' => 'confusion debuff.'
    }.freeze

    # @param room [Integer, nil] field refuge; nil keeps the legacy cycle
    # @param reasons [Array<String>] conditions recoverable in the field
    # @param commands [Array<String>] field-only arrival commands
    # @param scripts [Array<String>] field-only arrival scripts
    # @param waypoints [Array<Integer>] field return route
    # @param rally [Array<Integer>] field departure route
    # @param prep [Array<String>] field departure commands
    # @param timeout [Numeric] max field recovery seconds; zero disables
    # @param town_required [#call, nil] explicit extra town-service condition
    # @param after_town [String] resume or stop after town recovery
    def initialize(room: nil, reasons: %w[fried mana], commands: [], scripts: [], waypoints: [], rally: [], prep: [],
                   timeout: 900, town_required: nil, after_town: 'resume')
      @room, @commands, @scripts, @waypoints, @rally, @prep = room, commands, scripts, waypoints, rally, prep
      @reasons = reasons.map { |reason| REASONS.fetch(reason) { raise ArgumentError, "unknown field rest reason: #{reason}" } }
      @timeout = Float(timeout)
      @town_required = town_required
      @after_town = after_town
      raise ArgumentError, 'field rest timeout must be finite and nonnegative' unless @timeout.finite? && @timeout >= 0
      raise ArgumentError, 'after_town_rest must be resume or stop' unless %w[resume stop].include?(after_town)
      raise ArgumentError, 'field rest room must be a positive room id' unless room.nil? || (room.is_a?(Integer) && room.positive?)
      raise ArgumentError, 'field routes must contain positive room ids' unless (waypoints + rally).all? { |id| id.is_a?(Integer) && id.positive? }
    end

    # @return [Boolean] two-site routing is enabled
    def enabled? = !@room.nil?
    # @return [Float] field recovery deadline interval, zero disables
    attr_reader :timeout

    # @return [Integer, nil] configured field refuge
    attr_reader :room

    # @return [Boolean] stop after completed town recovery rather than depart
    def stop_after_town? = @after_town == 'stop'
    # @return [Boolean] caller's explicit service condition currently holds
    def town_required? = @town_required&.call ? true : false

    # Select town if any reason needs town; unknown reasons never go field.
    # @param reasons [Array<String>] all active reasons, in priority order
    # @return [Symbol] field or town
    def select(reasons)
      allowed = @reasons.map { |reason| reason.delete_suffix('.') }
      allowed << EO::Engine::BuffPolicy::FIELD_REASON.delete_suffix('.')
      enabled? && !reasons.empty? && reasons.all? { |reason| allowed.include?(reason.delete_suffix('.')) } ? :field : :town
    end

    # A duplicate policy retains shared thresholds but never inherits town travel
    # or town scripts. The profile's original policy is not mutated.
    # @param town [Policy] legacy/town settings
    # @param site [Symbol] selected rest destination
    # @return [Policy] effective lifecycle settings
    def policy(town, site)
      return town unless site == :field

      field = town.dup
      field.resting_room = @room
      field.return_waypoints = @waypoints
      field.rally_rooms = @rally
      field.resting_commands = @commands
      field.resting_scripts = @scripts
      field.hunting_prep_commands = @prep
      field.fog_return = 0
      field.custom_fog = []
      field
    end
  end
end
