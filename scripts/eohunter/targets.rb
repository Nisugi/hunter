# frozen_string_literal: true

# ============================================================================
# targets (bigshot's target selection: valid_target?, sort_npcs, priority)
# ============================================================================

#
# EO::Engine::Targets - which creature to fight, from bigshot's rules.
#
# Pure functions over a roster (the game's own target list, GameObj.targets)
# and a Policy built from the profile, so every rule is spec'd without Lich.
# The rules and their bigshot line references are in hunting-engine-plan.md,
# "Target selection".
#
#   policy = Targets::Policy.new(wanted: { 'kobold' => 'a', 'orc' => 'b' }, invalid: ['rat'])
#   Targets.choose(world.room.targets, policy, current: target, priority: true)
#
module EO::Engine
  module Targets
    # What the profile says about targets. +wanted+ maps a name or noun
    # pattern (anchored, case-insensitive, regex fragments allowed the way
    # bigshot's targets setting allows them) to a routine letter; nil or
    # empty means everything. +invalid+ is the invalid_targets list, by
    # name or noun. +untargetable+ is what the game has refused to TARGET
    # (learned, persisted by the caller). +boons_ignore+ names boon
    # abilities not to engage; +boon_abilities+ answers a creature's
    # abilities from ASSESS, or nil when unknown, and is only consulted
    # for creatures typed "boon".
    Policy = Struct.new(:wanted, :invalid, :untargetable, :boons_ignore, :boon_abilities, keyword_init: true) do
      def matchers
        @matchers ||= (wanted.nil? || wanted.empty? ? { '.+' => 'a' } : wanted).map { |key, letter| [/^#{key}$/i, letter] }
      end

      def invalid_list     = Array(invalid)
      # Learned at run time (Engage's TARGET probe), so it must be the
      # same array every call.
      def untargetable_set = (self.untargetable ||= [])
      def ignore_list      = Array(boons_ignore)
    end

    # bigshot 6892: severed limbs and other appendages the game lists as
    # targets.
    APPENDAGE_NOUNS = /^(?:arm|appendage|claw|limb|pincer|tentacle)s?$|^(?:palpus|palpi)$/i
    # bigshot 6893: summoned and elemental helpers, hazes and mists that
    # appear in the target list but are not the fight.
    SUMMONED_NOUNS = /^(?:grik|grik'trak|grik'mlar|grik'pwal|grik'tval|verlok|verlok'asha|verlok'cina|verlok'ar|imp|abyran|abyran'a|abyran'sa|grantris|igaesha|haze|rouk|brume|haar|murk|nyle|mist|smoke|vapor|fog|aishan|shien|darkling|shadowling|arashan)$/i
    # bigshot 6894
    NEVER_NAMES = ['quickly growing troll king', 'severed troll arm', 'severed troll leg'].freeze
    # bigshot 6912 / 5735: animated decoys, except the slush that is a real creature.
    ANIMATED = /animated/
    ANIMATED_REAL = /animated slush/

    # bigshot 2596-2625: the ASSESS adjectives that name a boon ability.
    BOON_ADJECTIVES = {
      'crit_death_immune'  => ['resolute', 'unflinching'],
      'crit_padding'       => ['stout', 'hardy'],
      'crit_weighting'     => ['shimmering', 'gleaming'],
      'damage_padding'     => ['flinty', 'tough'],
      'dmg_weighting'      => ['barbed', 'spiny'],
      'diseased'           => ['pestilent', 'afflicted', 'diseased'],
      'dispelling'         => ['dazzling', 'flashy'],
      'elem_flares'        => ['glittering'],
      'elemental_negation' => ['sparkling', 'shining'],
      'extra_elem'         => ['glowing'],
      'extra_spirit'       => ['radiant'],
      'extra_other'        => ['twinkling'],
      'ethereal'           => ['ethereal', 'wispy', 'ghostly'],
      'frenzy'             => ['raging', 'frenzied'],
      'jack'               => ['adroit', 'deft'],
      'magic_resistance'   => ['rune-covered', 'tattooed'],
      'mind_blast'         => ['canny', 'keen'],
      'parting_shot'       => ['dreary', 'drab'],
      'physical_negation'  => ['indistinct', 'nebulous'],
      'poisonous'          => ['sickly green', 'oozing'],
      'regen'              => ['slimy', 'muculent'],
      'soul'               => ['tenebrous', 'shadowy'],
      'stun_immune'        => ['steadfast', 'unyielding'],
      'terrifying'         => ['ghastly', 'grotesque'],
      'weaken'             => ['spindly', 'lanky']
    }.freeze
    BOON_BY_ADJECTIVE = BOON_ADJECTIVES.each_with_object({}) { |(ability, adjs), h| adjs.each { |a| h[a] = ability } }.freeze

    # ASSESS's "appears to be stout, glowing and raging" line to ability
    # names; nil when the line carries none.
    #
    # @param text [String] the ASSESS line, tags stripped
    # @return [Array<String>, nil]
    def self.boon_abilities_from(text)
      match = text.to_s.match(/appears to be (.+?)(?:\.|$)/i)
      return nil unless match

      abilities = match[1].downcase.split(/\s*(?:,|and)\s*/).map(&:strip).map { |adj| BOON_BY_ADJECTIVE[adj] }.compact.uniq
      abilities.empty? ? nil : abilities
    end

    # bigshot check_boons (8082) with its @BOON_CACHE: a boon creature's
    # abilities from one ASSESS, remembered by id for the run. The
    # Policy's boon_abilities callback. Only creatures typed "boon" are
    # ever assessed; a creature that could not be assessed is asked again
    # next time, one whose line named no ability is remembered as nil.
    class BoonCache
      # @param world [World]
      # @param assess [#call, nil] (creature) -> Result; default Actions::Assess
      def initialize(world, assess: nil)
        @world = world
        @assess = assess || ->(creature) { Actions::Assess.new(@world, target: creature).call }
        @known = {}
      end

      def abilities(creature)
        return nil unless creature.type.to_s.include?('boon')

        id = creature.id.to_s
        return @known[id] if @known.key?(id)

        result = @assess.call(creature)
        return nil unless result.success? || result.reason == :no_boons

        @known[id] = result.success? ? Targets.boon_abilities_from(result.line) : nil
      end

      def to_proc = method(:abilities).to_proc
    end

    class << self
      # Why a creature cannot be fought, or nil when it can. Order and
      # tests are bigshot's should_flee? reject list (6887-6896) plus
      # valid_target?'s animated and boon checks (6912-6913).
      #
      # @param creature [#id, #name, #noun, #status, #type]
      # @param policy [Policy]
      # @return [Symbol, nil] :dead, :invalid, :untargetable, :appendage,
      #   :summoned, :never, :companion, :animated, :boon
      def excluded_reason(creature, policy)
        return :dead if creature.status.to_s =~ /dead|gone/
        return :invalid if policy.invalid_list.include?(creature.name) || policy.invalid_list.include?(creature.noun)
        return :untargetable if policy.untargetable_set.include?(creature.name)
        return :appendage if creature.noun.to_s =~ APPENDAGE_NOUNS
        return :summoned if creature.noun.to_s =~ SUMMONED_NOUNS
        return :never if NEVER_NAMES.include?(creature.name)

        type = creature.type.to_s
        return :companion if type =~ /companion|familiar/i && type !~ /aggressive npc/i
        return :animated if creature.name.to_s =~ ANIMATED && creature.name.to_s !~ ANIMATED_REAL
        return :boon if boon_ignored?(creature, policy)

        nil
      end

      def excluded?(creature, policy) = !excluded_reason(creature, policy).nil?

      # bigshot invalid_target_with_boons (6833): only creatures typed
      # "boon", only when the profile ignores some ability, and only when
      # the abilities are known.
      def boon_ignored?(creature, policy)
        return false if policy.ignore_list.empty?
        return false unless creature.type.to_s.include?('boon')

        abilities = policy.boon_abilities&.call(creature)
        return false if abilities.nil?

        (Array(abilities) & policy.ignore_list).any?
      end

      # bigshot sort_npcs (6973) and priority_matchers (6982): the profile
      # names it, by name or noun, anchored.
      def wanted?(creature, policy)
        policy.matchers.any? { |rx, _| creature.name.to_s =~ rx || creature.noun.to_s =~ rx }
      end

      # The routine letter for a creature: its entry in the targets list,
      # 'a' when unlisted (bigshot find_routine 5988).
      def routine_for(creature, policy)
        entry = policy.matchers.find { |rx, _| creature.name.to_s =~ rx || creature.noun.to_s =~ rx }
        entry ? entry.last : 'a'
      end

      # bigshot priority_rank (6986): position in the targets list,
      # infinity when unlisted. Lower is better.
      def rank(creature, policy)
        index = policy.matchers.index { |rx, _| creature.name.to_s =~ rx || creature.noun.to_s =~ rx }
        index.nil? ? Float::INFINITY : index
      end

      # Fightable, wanted, in the order the profile lists them (stable
      # within a rank, so the game's own order breaks ties).
      #
      # @param roster [Array] the game's target list
      # @return [Array]
      def candidates(roster, policy)
        wanted = Array(roster).reject { |c| excluded?(c, policy) }.select { |c| wanted?(c, policy) }
        wanted.each_with_index.sort_by { |c, i| [rank(c, policy), i] }.map(&:first)
      end

      # How many fightable creatures are here, wanted or not: what
      # flee_count is compared against (bigshot should_flee? 6900,
      # gameobj_npc_check 5733).
      def fightable_count(roster, policy)
        Array(roster).count { |c| !excluded?(c, policy) }
      end

      # bigshot valid_target? (6903) minus the flee and TARGET-probe parts:
      # present in the roster, fightable, wanted.
      def valid?(creature, roster, policy)
        return false if creature.nil?
        return false unless Array(roster).any? { |c| c.id == creature.id }

        !excluded?(creature, policy) && wanted?(creature, policy)
      end

      # bigshot find_target (7010) with priority (6991): keep the current
      # target while it is valid; with +priority+ a creature that OUTRANKS
      # it (a strictly better rank, never a tie) takes over. Otherwise the
      # best candidate, or nil.
      #
      # @param current [Object, nil] the creature being fought
      # @param priority [Boolean] the profile's priority toggle
      def choose(roster, policy, current: nil, priority: false)
        ranked = candidates(roster, policy)
        if current && valid?(current, roster, policy)
          return current unless priority

          best = ranked.first
          return current if best.nil? || rank(best, policy) >= rank(current, policy)

          return best
        end
        ranked.first
      end
    end
  end
end
