# frozen_string_literal: true

module EO::Engine
  module Loadout
    # Named hunting hands selected before combat, with the profile baseline
    # between encounters. This Hunter extension reuses Targets' name matching
    # and Engage::Conditions' undead/noncorporeal tags; it issues no commands.
    class Selection
      # Supported creature selectors. Living requires an explicitly false
      # CreatureTemplate#undead fact; an uncatalogued creature is unknown.
      TYPES = %w[living undead noncorporeal].freeze

      # The baseline restored when there is no selected target or match.
      #
      # @return [Policy]
      attr_reader :default

      # Validate every set and rule eagerly so configuration errors surface
      # before the script installs observers or performs game actions.
      #
      # @param default [Policy] the profile's hunting hand baseline
      # @param sets [Hash{String, Symbol => Hash}] named right/left overrides
      # @param rules [Array<Hash>] ordered set, target and type selectors
      # @raise [ArgumentError] for malformed configuration or unknown sets
      def initialize(default:, sets: {}, rules: [])
        @default = default
        @sets = mapping(sets, 'hunting_loadout_sets').to_h do |name, hands|
          label = "hunting_loadout_sets.#{name}"
          text(name, 'hunting_loadout_sets name')
          hands = fields(hands, %w[right left], label)
          hands.each_value { |value| raise ArgumentError, "#{label} hands must be strings" unless value.is_a?(String) }
          begin
            [name, Policy.new(right: hands.fetch('right', default.right), left: hands.fetch('left', default.left))]
          rescue ArgumentError => e
            raise ArgumentError, "#{label}: #{e.message}"
          end
        end
        raise ArgumentError, 'hunting_loadout_rules must be an array' unless rules.is_a?(Array)

        @rules = rules.each_with_index.map { |rule, index| build_rule(rule, index) }
      end

      # Whether the baseline or a rule's selected policy manages either hand.
      # Saved sets without a selecting rule do not opt into hand management.
      #
      # @return [Boolean]
      def managed? = default.managed? || @rules.any? { |policy, _names, _type| policy.managed? }

      # First matching rule wins; target and type in one rule are ANDed.
      # The caller supplies the committed encounter target, not a room scan.
      #
      # @param target [#id, #name, #noun, #type, nil]
      # @param world [World] core creature classification reader
      # @return [Policy] selected set or the baseline
      def select(target:, world:)
        return default if target.nil?

        match = @rules.find do |_policy, names, type|
          (names.nil? || Targets.wanted?(target, names)) && (type.nil? || type_matches?(type, target, world))
        end
        match ? match.first : default
      end

      private

      def mapping(value, label)
        raise ArgumentError, "#{label} must be a mapping" unless value.is_a?(Hash)
        unless value.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
          raise ArgumentError, "#{label} keys must be names"
        end

        normalized = value.transform_keys(&:to_s)
        raise ArgumentError, "#{label} has duplicate keys" unless normalized.size == value.size

        normalized
      end

      def fields(value, allowed, label)
        value = mapping(value, label)
        unknown = value.keys - allowed
        raise ArgumentError, "#{label} unknown fields: #{unknown.join(', ')}" unless unknown.empty?

        value
      end

      def text(value, label)
        unless (value.is_a?(String) || value.is_a?(Symbol)) && !value.to_s.strip.empty?
          raise ArgumentError, "#{label} must be a nonblank name"
        end

        value.to_s
      end

      def build_rule(raw, index)
        label = "hunting_loadout_rules[#{index}]"
        rule = fields(raw, %w[set target type], label)
        name = text(rule['set'], "#{label}.set")
        raise ArgumentError, "#{label} unknown set: #{name}" unless @sets.key?(name)
        raise ArgumentError, "#{label} requires target or type" unless rule.key?('target') || rule.key?('type')

        if rule.key?('target')
          names = Targets::Policy.new(wanted: { text(rule['target'], "#{label}.target") => 'a' })
          begin
            names.matchers
          rescue RegexpError => e
            raise ArgumentError, "#{label}.target: #{e.message}"
          end
        end
        if rule.key?('type')
          type = text(rule['type'], "#{label}.type")
          raise ArgumentError, "#{label} unknown type: #{type}" unless TYPES.include?(type)
        end
        [@sets.fetch(name), names, type]
      end

      # The same comma-delimited tags as Engage::Conditions#word_skip?.
      # The living extension reads Lich's tri-state template fact through
      # World, so missing undead tags alone never imply a living creature.
      def type_matches?(type, target, world)
        tags = target.type.to_s.split(',')
        return tags.include?(type) unless type == 'living'
        return false if tags.include?('undead') || tags.include?('noncorporeal')

        world.creature(target.id)&.template&.undead == false
      end
    end
  end
end
