# frozen_string_literal: true

# ============================================================================
# loadout (the profile's authoritative between-fight hand state)
# ============================================================================

# Loadout owns only the baseline between encounters. Lich::Stash owns item
# discovery and the two-hand reconciliation; combat routines, Loot,
# Cleanse, Flee and Rest all outrank this behavior and retain their existing
# temporary hand ownership.
module EO::Engine
  # Parsing, matching and policy for the optional hunting hand baseline.
  module Loadout
    # One desired hand value: keep, empty, a ReadyList slot, or an item name.
    Reference = Struct.new(:kind, :value, keyword_init: true) do
      class << self
        # @param raw [Object] the profile value
        # @return [Reference]
        # @raise [ArgumentError] when a ready reference has no slot
        def parse(raw)
          text = raw.to_s.strip
          return new(kind: :keep, value: nil) if text.empty? || text.casecmp?('keep')
          return new(kind: :empty, value: nil) if text.casecmp?('empty')

          if text =~ /\Aready\s*:(.*)\z/i
            slot = Regexp.last_match(1).to_s.strip.downcase.tr(' -', '__').gsub(/_+/, '_').to_sym
            raise ArgumentError, 'ready reference must name a slot' if slot.to_s.empty?

            return new(kind: :ready, value: slot)
          end
          new(kind: :name, value: text)
        end
      end

      # The value Lich::Stash.hands accepts for this reference.
      #
      # @return [Symbol, String, nil]
      def stash_value
        case kind
        when :keep then :keep
        when :empty then nil
        else value
        end
      end

      # Compare one current hand without inventory commands.
      #
      # @param item [Object, nil] the hand's GameObj-like value
      # @param adapter [Core] the cached ReadyList/resolved-name adapter
      # @return [Boolean]
      def satisfied_by?(item, adapter: Core.new)
        case kind
        when :keep then true
        when :empty then item.nil? || item.id.nil?
        when :ready then same_item?(item, adapter.ready_item(value))
        when :name then !item.nil? && !item.id.nil? && adapter.name_match?(item, value)
        else false
        end
      end

      # Player-facing description used by diagnostics.
      #
      # @return [String]
      def description
        kind == :ready ? "ready:#{value}" : (kind == :name ? value.to_s : kind.to_s)
      end

      private

      def same_item?(actual, wanted)
        !actual.nil? && !wanted.nil? && !actual.id.nil? && actual.id.to_s == wanted.id.to_s
      end
    end

    # Both hand requirements, normalized once at profile load.
    Policy = Struct.new(:right, :left, keyword_init: true) do
      # @param right [Object] Reference or profile value
      # @param left [Object] Reference or profile value
      def initialize(right: 'keep', left: 'keep')
        super(right: reference(right), left: reference(left))
      end

      # @return [Boolean] whether either hand is managed
      def managed? = right.kind != :keep || left.kind != :keep

      # @param hands [Object] responds to right and left
      # @param adapter [Core]
      # @return [Boolean]
      def satisfied?(hands, adapter: Core.new)
        right.satisfied_by?(hands.right, adapter: adapter) && left.satisfied_by?(hands.left, adapter: adapter)
      end

      # @return [Hash{Symbol => Symbol, String, nil}] arguments for Stash.hands
      def stash_arguments = { right: right.stash_value, left: left.stash_value }

      # @return [String]
      def description = "right #{right.description}, left #{left.description}"

      private

      def reference(value) = value.is_a?(Reference) ? value : Reference.parse(value)
    end

    # The only adapter to Lich inventory state. Predicates use the cached
    # ReadyList; the action delegates the entire mutation to Stash.hands.
    class Core
      # @param world [World] cached game-state reader
      def initialize(world: World.new)
        @world = world
        @resolved_names = {}
      end

      # A cached ReadyList item. This never runs READY LIST.
      #
      # @param slot [Symbol]
      # @return [Object, nil]
      def ready_item(slot)
        @world.ready_item(slot)
      end

      # Match the id resolved by the last successful Stash transaction.
      # An unresolved name requests one action, where core may inspect
      # inventory; predicates never invoke its inventory-refresh fallback.
      #
      # @param item [Object]
      # @param name [String]
      # @return [Boolean]
      def name_match?(item, name)
        id = @resolved_names[name.to_s]
        !id.nil? && !item.nil? && !item.id.nil? && item.id.to_s == id
      end

      # @param right [Symbol, String, nil]
      # @param left [Symbol, String, nil]
      # @return [Hash]
      def reconcile(right:, left:)
        result = ::Lich::Stash.hands(right: right, left: left)
        { right: right, left: left }.each do |hand, wanted|
          next unless wanted.is_a?(String)

          @resolved_names[wanted] = result[hand]&.id&.to_s
        end
        result
      end
    end
  end

  module Actions
    # Ask Lich::Stash for one complete two-hand reconciliation, then verify
    # the live hand snapshot. No item movement protocol lives in EOHunter.
    class EstablishLoadout < Base
      # @param world [World]
      # @param policy [Loadout::Policy]
      # @param adapter [Loadout::Core]
      def initialize(world, policy:, adapter: Loadout::Core.new, **opts)
        super(world, **opts)
        @policy = policy
        @adapter = adapter
      end

      # @return [Symbol] :ok or the shared safety refusal
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # @return [Result]
      def perform
        # Like Wield/Store, Stash owns the command seam. Do not invent an
        # acted stamp: resolution may fail or finish without sending.
        @adapter.reconcile(**@policy.stash_arguments)
        if @policy.satisfied?(@world.hands, adapter: @adapter)
          Result.new(status: :success, reason: :established)
        else
          Result.new(status: :failed, reason: :verification_failed,
                     line: "hands did not become #{@policy.description}")
        end
      rescue StandardError => e
        Result.new(status: :failed, reason: classify(e), line: e.message)
      end

      private

      def classify(error)
        message = error.message.to_s
        return :item_missing if message =~ /could not find Item|ready-list .* (?:is empty|not set)/i
        return :item_inaccessible if message =~ /locked|would not open|inaccessible/i
        return :invalid_loadout if error.is_a?(ArgumentError) || message =~ /asked for in both hands|asked to be kept|unknown ready-list slot/i

        :reconciliation_failed
      end
    end
  end

  module Behaviors
    # Restores the configured baseline only when no higher subsystem or live
    # combat routine owns the hands.
    class Loadout < Behavior
      # @param policy [EO::Engine::Loadout::Policy]
      # @param owner [#owns_hands?] Engage or Assist
      # @param adapter [EO::Engine::Loadout::Core]
      # @param resting [#call] whether the rest lifecycle owns the hands
      def initialize(policy:, owner:, adapter: EO::Engine::Loadout::Core.new, resting: -> { false })
        super()
        @policy = policy
        @owner = owner
        @adapter = adapter
        @resting = resting
        @stuck = nil
      end

      # Between Loot (30) and Maintain (40).
      # @return [Integer] 35
      def priority = 35

      # @return [Boolean] whether the latest reconciliation failed
      def stuck? = !@stuck.nil?

      # @return [Hash, nil] the latest failure
      attr_reader :stuck

      # @param world [World]
      # @return [Boolean]
      def satisfied?(world) = @policy.satisfied?(world.hands, adapter: @adapter)

      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        return false unless @policy.managed?
        return false if Travel.active&.underway?
        return true if stuck?
        return false if @resting.call
        return false if @owner&.owns_hands?(world)

        !satisfied?(world)
      end

      # @param world [World]
      # @return [Actions::Result]
      def tick(world)
        # Failure is terminal for this hunt. Hold lower-priority work while
        # the existing solo or group return lifecycle takes over.
        return nil if stuck?

        result = Actions::EstablishLoadout.new(world, policy: @policy, adapter: @adapter).call
        if result.success?
          @stuck = nil
        else
          record_failure(world, result)
        end
        result
      end

      private

      def record_failure(world, result)
        @stuck = { room: world.room.id, reason: result.reason, message: result.line, wanted: @policy.description }
        Events.emit(:loadout_stuck, @stuck)
      end
    end
  end
end
