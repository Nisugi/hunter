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
  # Which creature to fight, from bigshot's rules: pure functions over the
  # game's target list and a Policy built from the profile, plus the boon
  # ability cache that valid_target?'s boon check reads.
  #
  # @bigshot valid_target?
  # @bigshot sort_npcs
  # @bigshot find_target
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
      # The wanted list as anchored, case-insensitive patterns paired with
      # their routine letters; everything on 'a' when the list is empty.
      # Built once and kept.
      #
      # @return [Array<Array(Regexp, String)>]
      def matchers
        @matchers ||= (wanted.nil? || wanted.empty? ? { '.+' => 'a' } : wanted).map { |key, letter| [/^#{key}$/i, letter] }
      end

      # The invalid_targets names and nouns, always an Array.
      #
      # @return [Array<String>]
      def invalid_list     = Array(invalid)
      # Learned at run time (Engage's TARGET probe), so it must be the
      # same array every call.
      #
      # @return [Array<String>] the names the game refused to TARGET
      def untargetable_set = (self.untargetable ||= [])
      # The boon abilities not to engage, always an Array.
      #
      # @return [Array<String>]
      def ignore_list      = Array(boons_ignore)
    end

    # The roster is Lich's GameObj.targets, which already drops the dead
    # and gone, severed appendages (keeping the kraken tentacles that
    # are real targets) and animated decoys other than the slush. Only
    # what Lich does not know is filtered here.
    #
    # bigshot: summoned and elemental helpers, hazes and mists that
    # appear in the target list but are not the fight.
    #
    # @bigshot should_flee?
    SUMMONED_NOUNS = /^(?:grik|grik'trak|grik'mlar|grik'pwal|grik'tval|verlok|verlok'asha|verlok'cina|verlok'ar|imp|abyran|abyran'a|abyran'sa|grantris|igaesha|haze|rouk|brume|haar|murk|nyle|mist|smoke|vapor|fog|aishan|shien|darkling|shadowling|arashan)$/i
    # bigshot: names never fought, whatever the profile says.
    #
    # @bigshot should_flee?
    NEVER_NAMES = ['quickly growing troll king', 'severed troll arm', 'severed troll leg'].freeze

    # The creature appendages that make Grasp of the Grave a bad
    # idea: the spell grabs at legs, and a severed limb has none.
    # ecleanse reads the room's npcs for these before casting it.
    #
    # Matched against the noun, where ecleanse matches the name. The
    # pattern is anchored and ecleanse's is too, so against Lich's name
    # ("a writhing tentacle", gameobj.rb 170) it only ever fires on an
    # appendage the game happens to name bare; the noun ("tentacle") is
    # what the pattern actually describes, and is how this engine matches
    # every other creature word (the web, the nest, the spirit).
    #
    # @ecleanse settle_room 1505
    APPENDAGE_NOUNS = /^(?:arm|appendage|claw|limb|pincer|tentacle)s?$|^(?:palpus|palpi)$/i

    # bigshot: the ASSESS adjectives that name a boon ability.
    #
    # @bigshot boon adjectives
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
    # BOON_ADJECTIVES inverted: each adjective to the ability it names.
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

    # bigshot check_boons with its @BOON_CACHE: a boon creature's
    # abilities from one ASSESS, remembered by id for the run. The
    # Policy's boon_abilities callback is +call+, which only READS: the
    # predicates run before the engine hands control over, while a trip
    # may still be walking, so nothing is sent from them. An unknown boon
    # creature is noted as pending and answers nil (unknown) until Engage,
    # holding the tick, runs +assess!+ on it; the next predicate pass sees
    # the abilities. A creature that could not be assessed stays pending;
    # one whose line named no ability is remembered as nil.
    #
    # @bigshot check_boons
    class BoonCache
      # @param world [World]
      # @param assess [#call, nil] (creature) -> Result; default Actions::Assess
      def initialize(world, assess: nil)
        @world = world
        @assess = assess || ->(creature) { Actions::Assess.new(@world, target: creature).call }
        @known = {}
        @pending = {}
      end

      # The read-only answer: known abilities, or nil (unknown) with the
      # creature noted for assessment.
      #
      # @param creature [#id, #type]
      # @return [Array<String>, nil] the abilities; nil when not a boon
      #   creature, not yet assessed, or assessed with none
      def call(creature)
        return nil unless creature.type.to_s.include?('boon')

        id = creature.id.to_s
        return @known[id] if @known.key?(id)

        @pending[id] = creature
        nil
      end

      # A pending creature still in +roster+, or nil.
      #
      # @param roster [Array] the game's target list
      # @return [Object, nil] the creature noted for assessment
      def next_pending(roster)
        here = Array(roster).map { |c| c.id.to_s }
        @pending.each_value.find { |c| here.include?(c.id.to_s) }
      end

      # Any creature noted for assessment, here or not.
      #
      # @return [Boolean]
      def pending? = !@pending.empty?

      # The ASSESS, from a behavior that holds the tick.
      #
      # @param creature [#id]
      # @return [Actions::Result] the assess's Result; on success or
      #   :no_boons the creature leaves pending and its abilities are kept
      def assess!(creature)
        result = @assess.call(creature)
        id = creature.id.to_s
        if result.success? || result.reason == :no_boons
          @known[id] = result.success? ? Targets.boon_abilities_from(result.line) : nil
          @pending.delete(id)
        end
        result
      end
    end

    class << self
      # Why a creature on the roster cannot be fought, or nil when it
      # can. Order and tests are bigshot's should_flee? reject list
      # (6887-6896) plus valid_target?'s boon check, less what
      # GameObj.targets already removed.
      #
      # @param creature [#id, #name, #noun, #status, #type]
      # @param policy [Policy]
      # @return [Symbol, nil] :invalid, :untargetable, :summoned, :never,
      #   :companion, :boon
      # @bigshot should_flee?
      # @bigshot valid_target?
      def excluded_reason(creature, policy)
        return :invalid if policy.invalid_list.include?(creature.name) || policy.invalid_list.include?(creature.noun)
        return :untargetable if policy.untargetable_set.include?(creature.name)
        return :summoned if creature.noun.to_s =~ SUMMONED_NOUNS
        return :never if NEVER_NAMES.include?(creature.name)

        type = creature.type.to_s
        return :companion if type =~ /companion|familiar/i && type !~ /aggressive npc/i
        return :boon if boon_ignored?(creature, policy)

        nil
      end

      # Whether +excluded_reason+ names one.
      #
      # @param creature [#id, #name, #noun, #status, #type]
      # @param policy [Policy]
      # @return [Boolean]
      def excluded?(creature, policy) = !excluded_reason(creature, policy).nil?

      # bigshot invalid_target_with_boons: only creatures typed
      # "boon", only when the profile ignores some ability, and only when
      # the abilities are known.
      #
      # @param creature [#type]
      # @param policy [Policy]
      # @return [Boolean]
      # @bigshot invalid_target_with_boons
      def boon_ignored?(creature, policy)
        return false if policy.ignore_list.empty?
        return false unless creature.type.to_s.include?('boon')

        abilities = policy.boon_abilities&.call(creature)
        return false if abilities.nil?

        (Array(abilities) & policy.ignore_list).any?
      end

      # bigshot sort_npcs and priority_matchers: the profile
      # names it, by name or noun, anchored.
      #
      # @param creature [#name, #noun]
      # @param policy [Policy]
      # @return [Boolean]
      # @bigshot sort_npcs
      # @bigshot priority_matchers
      def wanted?(creature, policy)
        policy.matchers.any? { |rx, _| creature.name.to_s =~ rx || creature.noun.to_s =~ rx }
      end

      # The routine letter for a creature: its entry in the targets list,
      # 'a' when unlisted (bigshot find_routine 5988).
      #
      # @param creature [#name, #noun]
      # @param policy [Policy]
      # @return [String] a letter 'a'..'j', or 'quick'
      # @bigshot find_routine
      def routine_for(creature, policy)
        entry = policy.matchers.find { |rx, _| creature.name.to_s =~ rx || creature.noun.to_s =~ rx }
        entry ? entry.last : 'a'
      end

      # bigshot priority_rank: position in the targets list,
      # infinity when unlisted. Lower is better.
      #
      # @param creature [#name, #noun]
      # @param policy [Policy]
      # @return [Integer, Float] the index, or Float::INFINITY
      # @bigshot priority_rank
      def rank(creature, policy)
        index = policy.matchers.index { |rx, _| creature.name.to_s =~ rx || creature.noun.to_s =~ rx }
        index.nil? ? Float::INFINITY : index
      end

      # Fightable, wanted, in the order the profile lists them (stable
      # within a rank, so the game's own order breaks ties).
      #
      # @param roster [Array] the game's target list
      # @param policy [Policy]
      # @return [Array] the creatures, best rank first
      def candidates(roster, policy)
        wanted = Array(roster).reject { |c| excluded?(c, policy) }.select { |c| wanted?(c, policy) }
        wanted.each_with_index.sort_by { |c, i| [rank(c, policy), i] }.map(&:first)
      end

      # How many fightable creatures are here, wanted or not: what
      # flee_count is compared against (bigshot should_flee? 6900,
      # gameobj_npc_check 5733).
      #
      # @param roster [Array] the game's target list
      # @param policy [Policy]
      # @return [Integer]
      # @bigshot should_flee?
      # @bigshot gameobj_npc_check
      def fightable_count(roster, policy)
        Array(roster).count { |c| !excluded?(c, policy) }
      end

      # bigshot valid_target? minus the flee and TARGET-probe parts:
      # present in the roster, fightable, wanted.
      #
      # @param creature [#id, #name, #noun, #type, nil]
      # @param roster [Array] the game's target list
      # @param policy [Policy]
      # @return [Boolean]
      # @bigshot valid_target?
      def valid?(creature, roster, policy)
        return false if creature.nil?
        return false unless Array(roster).any? { |c| c.id == creature.id }

        !excluded?(creature, policy) && wanted?(creature, policy)
      end

      # bigshot find_target with priority: keep the current
      # target while it is valid; with +priority+ a creature that OUTRANKS
      # it (a strictly better rank, never a tie) takes over. Otherwise the
      # best candidate, or nil.
      #
      # @param roster [Array] the game's target list
      # @param policy [Policy]
      # @param current [Object, nil] the creature being fought
      # @param priority [Boolean] the profile's priority toggle
      # @return [Object, nil] the creature to fight, or nil for none
      # @bigshot find_target
      # @bigshot priority
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
