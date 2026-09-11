# frozen_string_literal: true

module EO::Engine
  module Actions
    # Temporary bounded query adapter until core exposes observed MANA uses.
    # It reports availability only; casting policy remains in Maintain.
    class ManaSpellupStatus < Base
      USES = /^\s*You have used the MANA SPELLUP ability (\d+) out of (\d+) times for today\./.freeze

      # @return [Symbol] query only while the character is alive
      def preconditions = me.dead? ? :dead : :ok

      # @return [Actions::Result] available, exhausted, or unconfirmed
      def perform
        result = send_and_match('mana', USES, timeout: 2)
        return result unless result.success?

        match = USES.match(result.line)
        used, total = match.captures.map(&:to_i)
        result.reason = if used > total
                          :unknown_allowance
                        elsif used == total
                          :exhausted
                        else
                          :available
                        end
        result
      end
    end
  end

  # Opt-in desired effects over Lich's spell observations. This module never
  # sends commands, launches scripts, or moves the player. Maintain executes
  # native casts; Rest owns recovery and verifies readiness before departure.
  module BuffPolicy
    FIELD_REASON = 'required buffs missing (field).'
    TOWN_REASON = 'required buffs missing (town).'
    ACTIONS = %w[recast field town warn ignore].freeze
    Rule = Struct.new(:spell, :action, :required, :failure, keyword_init: true)
    Need = Struct.new(:rule, :state, keyword_init: true)

    # Validated, explicit spell requirements. No startup-buff snapshot is
    # inferred: consumable effects must only be monitored by deliberate choice.
    class Policy
      attr_reader :rules, :attempts, :verify_seconds, :recovery_seconds, :mana_spellup_at

      # @param raw [Hash] profile combat_buffs mapping, string keys
      # @raise [ArgumentError] malformed or ambiguous policy
      def initialize(raw = {})
        keys!(raw, %w[enabled default_action on_failure max_attempts verify_seconds recovery_seconds mana_spellup_at spells])
        @enabled = boolean(raw.fetch('enabled', false), 'enabled')
        default = action(raw.fetch('default_action', 'field'))
        failure = destination(raw.fetch('on_failure', 'field'))
        @attempts = raw.fetch('max_attempts', 2)
        raise ArgumentError, 'combat_buffs max_attempts must be an integer from 1 to 3' unless @attempts.is_a?(Integer) && (1..3).cover?(@attempts)

        @verify_seconds = seconds(raw.fetch('verify_seconds', 3), 'verify_seconds')
        @recovery_seconds = seconds(raw.fetch('recovery_seconds', 15), 'recovery_seconds')
        @mana_spellup_at = raw.fetch('mana_spellup_at', 0)
        unless @mana_spellup_at.is_a?(Integer) && (@mana_spellup_at.zero? || (2..100).cover?(@mana_spellup_at))
          raise ArgumentError, 'combat_buffs mana_spellup_at must be 0 (disabled) or an integer from 2 to 100'
        end
        spells = raw.fetch('spells', {})
        raise ArgumentError, 'combat_buffs spells must be a mapping of spell numbers to rules' unless spells.is_a?(Hash)

        @rules = spells.map do |id, value|
          raise ArgumentError, "combat_buffs invalid spell number #{id.inspect}" unless id.to_s.match?(/\A[1-9]\d*\z/)

          value = { 'action' => value } if value.is_a?(String)
          keys!(value, %w[action required on_failure])
          response = action(value.fetch('action', default))
          required = boolean(value.fetch('required', !%w[warn ignore].include?(response)), 'required')
          raise ArgumentError, 'combat_buffs warn/ignore rules cannot be required' if required && %w[warn ignore].include?(response)

          Rule.new(spell: id.to_i, action: response, required: required,
                   failure: destination(value.fetch('on_failure', failure))).freeze
        end.freeze
        raise ArgumentError, 'combat_buffs contains duplicate spell numbers' unless @rules.map(&:spell).uniq.size == @rules.size
        raise ArgumentError, 'enabled combat_buffs needs at least one explicit spell' if @enabled && @rules.empty?
      end

      # @return [Boolean] false preserves legacy behavior
      def enabled? = @enabled

      private

      def keys!(hash, allowed)
        raise ArgumentError, 'combat_buffs settings must be a mapping' unless hash.is_a?(Hash)
        unknown = hash.keys - allowed
        raise ArgumentError, "combat_buffs unknown settings: #{unknown.join(', ')}" unless unknown.empty?
      end

      def boolean(value, name)
        raise ArgumentError, "combat_buffs #{name} must be true or false" unless [true, false].include?(value)
        value
      end

      def action(value)
        raise ArgumentError, "combat_buffs invalid action #{value.inspect}" unless ACTIONS.include?(value)
        value
      end

      def destination(value)
        raise ArgumentError, 'combat_buffs on_failure must be field or town' unless %w[field town].include?(value)
        value
      end

      def seconds(value, name)
        raise ArgumentError, "combat_buffs #{name} must be a finite number from 1 to 60 seconds" unless value.is_a?(Numeric) && value.finite? && (1..60).cover?(value)
        value.to_f
      end
    end

    # Per-run retry bookkeeping, not a duplicate spell tracker. Observed active
    # effects clear their loss episode; command success alone never clears it.
    class Coordinator
      attr_reader :policy

      # @param policy [Policy]
      # @param clock [#now] monotonic retry clock
      def initialize(policy:, clock: Rest::Clock)
        @policy, @clock = policy, clock
        @episodes = {}
        @reported = nil
        @spellup_blocked = false
        @spellup_pending = nil
        @spellup_available = nil
        @spellup_checked_until = 0
      end

      # @return [Boolean]
      def enabled? = policy.enabled?

      # @param id [Integer] a legacy signs entry
      # @return [Boolean] explicit policy owns this entry, including ignore
      def manages?(id) = enabled? && policy.rules.any? { |rule| rule.spell == id }

      # Reads core observations; only retry state and deduplicated diagnostics
      # change here. A missing spell definition is unavailable, never castable.
      # @param world [World]
      # @return [Array<Need>] current unsatisfied rules
      def assess(world)
        return [] unless enabled?

        needs = policy.rules.filter_map do |rule|
          spell = world.spell[rule.spell]
          if spell && (spell.active? || world.me.effect_active?(spell.name))
            @episodes.delete(rule.spell)
            next
          end
          next if rule.action == 'ignore'

          state = rule.action
          if state == 'recast'
            episode = @episodes[rule.spell]
            state = if episode && @clock.now < episode[:until]
                      'pending'
                    elsif episode && episode[:attempts] >= policy.attempts
                      rule.failure
                    elsif !restorable?(spell)
                      rule.failure
                    else
                      'recast'
                    end
          end
          Need.new(rule: rule, state: state).freeze
        end
        settle_spellup(needs)
        needs = offer_spellup(world, needs)
        report(needs)
        needs
      end

      # @param world [World]
      # @return [String, nil] town wins when multiple destinations are needed
      def rest_reason(world)
        states = assess(world).map(&:state)
        return TOWN_REASON if states.include?('town')
        FIELD_REASON if states.include?('field')
      end

      # @param world [World]
      # @return [Array<Integer>] departure requirements, even when a cast is pending
      def missing_required(world) = assess(world).select { |need| need.rule.required }.map { |need| need.rule.spell }

      # Reserve an attempt before executing the existing casting action.
      # The caller must not call this until it owns the action slot.
      # @param id [Integer]
      # @return [void]
      def attempted!(id)
        previous = @episodes[id]
        @episodes[id] = { attempts: previous ? previous[:attempts] + 1 : 1, until: @clock.now + policy.verify_seconds }
      end

      # Reserve one bulk attempt for this loss. Observed restoration permits
      # a later attempt; failure disables bulk for this run, not native recasts.
      # @param ids [Array<Integer>] missing native buffs selected by assess
      # @return [void]
      def spellup_attempted!(ids)
        @spellup_checked_until = 0
        @spellup_pending = { ids: ids.dup, until: @clock.now + policy.verify_seconds }
        ids.each { |id| @episodes[id] = { attempts: 0, until: @clock.now + policy.verify_seconds } }
      end

      # A bounded MANA query precedes bulk use. Negative/unknown observations
      # suppress queries briefly, not across daily resets or whole sessions.
      # @param available [Boolean] freshly observed remaining uses are positive
      # @return [void]
      def spellup_checked!(available)
        @spellup_available = available
        @spellup_checked_until = @clock.now + (available ? 5 : 60)
      end

      private

      def settle_spellup(needs)
        return unless @spellup_pending

        missing = needs.map { |need| need.rule.spell }
        if (@spellup_pending[:ids] & missing).empty?
          @spellup_pending = nil
        elsif @clock.now >= @spellup_pending[:until]
          @spellup_blocked = true
          @spellup_pending = nil
        end
      end

      def offer_spellup(world, needs)
        return needs if @spellup_blocked || @spellup_pending || policy.mana_spellup_at.zero? || needs.any? { |need| need.state == 'pending' }
        fresh = @clock.now < @spellup_checked_until
        return needs if fresh && !@spellup_available

        candidates = needs.select do |need|
          need.rule.action == 'recast' && !@episodes.key?(need.rule.spell) && native_buff?(world.spell[need.rule.spell])
        end
        return needs if candidates.size < policy.mana_spellup_at

        state = fresh ? 'spellup' : 'spellup_check'
        needs.map { |need| candidates.include?(need) ? Need.new(rule: need.rule, state: state).freeze : need }
      end

      # Reuse core metadata, not a parallel spell catalog. Attack spells and
      # timers are not player-buff restoration, even if entered by mistake.
      def restorable?(spell)
        native_buff?(spell) && spell.affordable?
      end

      def native_buff?(spell)
        spell && spell.known? && !spell.type.to_s.empty? &&
          spell.type.to_s !~ /\b(?:attack|timer)\b/i && spell.time_per.to_f.positive?
      end

      def report(needs)
        status = needs.map { |need| [need.rule.spell, need.state] }
        return if status == @reported
        @reported = status
        Events.emit(:buff_policy_status, needs: status, ready: needs.none? { |need| need.rule.required })
      end
    end
  end
end
