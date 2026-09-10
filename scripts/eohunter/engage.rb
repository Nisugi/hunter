# frozen_string_literal: true

# ============================================================================
# engage (bigshot's attack loop: find_routine, command_check, cmd,
#         cmd_spell, the TARGET probe, wait_for_swing)
# ============================================================================

#
# bigshot's fight is do_hunt (6146) -> attack (6533) -> cmd (3296) per
# routine line, with attack_break (6512) between lines. The routine is
# the profile's command list for the creature's letter (find_routine
# 5980); each line may carry modifiers in parentheses (command_check
# 3539, check_state_condition 3589); cmd dispatches the verb (3406-3504)
# and registers "once" lines (3509). The engine's Engage is that as the
# behavior at priority 50: one routine line per tick, so Survival, Flee,
# Rest, Loot and Maintain all land between lines the way attack_break
# lets them. Rules and bigshot line references in hunting-engine-plan.md,
# "Engage".
#
module EO::Engine
  module Engage
    # hunting_commands(_b..j) / quick_commands / disable_commands /
    # priority / hunting_stance / wander_stance / wand_if_oom / oom /
    # use_wracking / ambush / aim from the profile (2870-2947).
    Policy = Struct.new(:routines, :quick_commands, :disable_commands, :priority, :hunting_stance, :wander_stance,
                        :wand_if_oom, :use_wracking, :oom, :ambush, :quick,
                        :archery_aim, :aim, :tier3, :uac_smite, :uac_mstrike, :ammo_container, :fresh_wand_container,
                        :dead_wand_container, :wand, :weapon_reaction, keyword_init: true) do
      def initialize(routines: {}, quick_commands: [], disable_commands: [], priority: false, hunting_stance: 'defensive',
                     wander_stance: 'defensive', wand_if_oom: false, use_wracking: false, oom: 0, ambush: [], quick: false,
                     archery_aim: [], aim: [], tier3: 'punch', uac_smite: false, uac_mstrike: false, ammo_container: nil,
                     fresh_wand_container: nil, dead_wand_container: nil, wand: [], weapon_reaction: true) = super

      # find_routine (5980): the letter's list, else the default (a).
      def routine_for(letter)
        return Array(quick_commands) if letter == 'quick' && Array(quick_commands).any?

        list = routines[letter.to_s]
        list.nil? || list.empty? ? Array(routines['a']) : list
      end
    end

    # What the fight learned: per-room once/room registry, the once-per
    # target spell lists, the unarmed tier, Swift Justice charges.
    class State
      attr_accessor :unarmed_tier, :swift_justice, :arcane_reflex, :combat_blocked_room
      attr_reader :registry, :cast_703, :cast_1614, :untargetable_learned

      def initialize
        @registry = {} # npc id => { command => Time }
        @cast_703 = []
        @cast_1614 = []
        @untargetable_learned = []
        @unarmed_tier = 1
        @swift_justice = 0
        @arcane_reflex = false
        @ally_attack_generation = Hash.new(0)
        @ally_cast_generation = {}
        @ally_cast_mutex = Mutex.new
        routines_reset!
      end

      def new_room!(room_id = nil)
        @registry.clear
        @cast_703.clear
        @cast_1614.clear
        @combat_blocked_room = nil unless room_id && @combat_blocked_room.to_s == room_id.to_s
        routines_reset!
      end

      # "You bolt" (hunt_monitor 2801): every per-fight latch
      def bolted!
        @cast_703.clear
        @cast_1614.clear
        @unarmed_tier = 1
        routines_reset!
      end

      def register(npc_id, command, at = Time.now)
        (@registry[npc_id.to_s] ||= {})[command] = at
      end

      def done_once?(npc_id, command) = @registry[npc_id.to_s]&.key?(command) || false

      def done_in_room?(command) = @registry.values.any? { |cmds| cmds.key?(command) }

      # repeatdelay_blocked? (3520)
      def last_run(command) = @registry.values.filter_map { |cmds| cmds[command] }.max

      # An afterattack allycast may run once initially, then once after each
      # observed attack by that named ally. Each routine line keeps its own
      # latch, so several support spells can all re-arm on the same attack.
      def ally_cast_ready?(command, name)
        ally = name.to_s.downcase
        @ally_cast_mutex.synchronize do
          key = [command.to_s, ally]
          !@ally_cast_generation.key?(key) || @ally_cast_generation[key] < @ally_attack_generation[ally]
        end
      end

      def ally_cast_done!(command, name)
        ally = name.to_s.downcase
        @ally_cast_mutex.synchronize { @ally_cast_generation[[command.to_s, ally]] = @ally_attack_generation[ally] }
      end

      def ally_attacked!(name)
        ally = name.to_s.downcase
        return if ally.empty?

        @ally_cast_mutex.synchronize { @ally_attack_generation[ally] += 1 }
      end
    end

    # One routine line: the text bigshot sends, and its modifiers.
    Line = Struct.new(:raw, :text, :modifiers, keyword_init: true) do
      def once? = modifiers.include?('once')
    end

    module Routine
      # @COMMAND_MODIFIER_REGEX (2634), reduced to "the trailing
      # parenthesis holds the modifiers"; each known word is checked in
      # Conditions, unknown words are reported and ignored.
      MODIFIERS = /\((.*?)\)$/

      module_function

      # An "a and b" entry (clean_value 2993) is an Array: its lines run
      # in order, the way bigshot's cmd runs an Array.
      def parse(entries)
        Array(entries).flatten.map do |raw|
          raw = raw.to_s.strip
          match = raw.match(MODIFIERS)
          mods = match ? match[1].scan(/(?:[^\s"]|"[^"]*")+/) : []
          Line.new(raw: raw, text: (match ? raw.sub(MODIFIERS, '') : raw).strip.downcase, modifiers: mods)
        end
      end
    end

    # command_check (3539): every modifier that says "skip this line now".
    module Conditions
      AMOUNT = /^(!?(?:e|essence|h|k|m|mob|s|tier|v|valid))(\d+)$/i
      BUFF = /^buff(\d+)$/i
      REPEAT = /^repeatdelay(\d+)$/i
      EFFECTS = /^(!?E[SBCD])"(.+)"$/i
      EMPOWERED = /^(!?)empowered(\d+)$/i
      THP = /^(!?)thp(\d+)$/i

      # bigshot 5.16 (4452-4509): crtrStatus statuses and classification
      # flags, and the Combat::Tracker facts, read off the CreatureInstance.
      # Positional statuses are read natively too (npc_prone? 8444). Lich
      # registers a creature the moment the feed names it, so a target
      # with no instance answers no status; nothing parses the GameObj
      # status string.
      STATUS_WORDS = %w[calm disoriented hovering immobilized kneeling sitting sleeping stunned webbed].freeze
      FLAG_WORDS = %w[ascended ascension_boss challenging disengaged inferior mini_boss mount rider sympathetic].freeze
      PRONE_STATUSES = %w[sleeping webbed stunned kneeling sitting prone immobilized].freeze

      # @COMMAND_BUFF_CHECKS (2665)
      BUFF_OF = {
        'barrage'     => 'Enh. Dexterity (+10)', 'bearhug' => 'Enh. Strength (+10)', 'coupdegrace' => /Empowered \(\+\d+\)/,
        'flurry'      => 'Slashing Strikes', 'fury' => 'Enh. Constitution (+10)', 'garrote' => 'Enh. Agility (+10)',
        'kweed'       => 'Tangleweed Vigor', 'pummel' => 'Concussive Blows', 'shout' => 'Empowered (+20)',
        'thrash'      => 'Forceful Blows', 'weed' => 'Tangleweed Vigor', 'yowlp' => "Yertie's Yowlp"
      }.freeze

      # check_state_condition (3607): a word is a "skip" when its lambda is
      # true. Effects by buff name; creature facts by status and type.
      BUFF_WORDS = {
        'barrage' => 'Enh. Dexterity (+10)', 'celerity' => 506, '506' => 506, 'coupdegrace' => /Empowered \(\+\d+\)/,
        'flurry' => 'Slashing Strikes', 'fury' => 'Enh. Constitution (+10)', 'garrote' => 'Enh. Agility (+10)',
        'holler' => 'Enh. Health (+20)', 'momentum' => 'Glorious Momentum', 'pummel' => 'Concussive Blows',
        'rapid' => 'Rapid Fire', 'rebuke' => 'Righteous Rebuke', 'scourge' => 'Ardor of the Scourge',
        'shout' => 'Empowered (+20)', 'tailwind' => 'Breeze Archery Tailwind', 'thrash' => 'Forceful Blows',
        'vigor' => 'Tangleweed Vigor', 'yowlp' => "Yertie's Yowlp", 'animate' => 'Animate Dead'
      }.freeze

      module_function

      # @return [String, nil] the modifier that blocks the line, or nil
      def blocked_by(line, world, target, state, targets_policy, now: Time.now)
        line.modifiers.find { |mod| skip?(mod, line, world, target, state, targets_policy, now) }
      end

      def skip?(mod, line, world, target, state, targets_policy, now)
        me = world.me
        if (m = mod.match(AMOUNT))
          return amount_skip?(m[1].downcase, m[2].to_i, world, state, targets_policy)
        end
        if (m = mod.match(BUFF))
          # 5.16 fix (4261-4285): the buff comes from the command word, and
          # only a buff that is UP with N seconds left vetoes; time_left is
          # 0 for an absent buff, which would deadlock a command whose buff
          # comes from the command (coup de grace -> Empowered).
          key = BUFF_OF.keys.find { |k| line.text =~ /^#{Regexp.escape(k)}\b/i }
          buff = key && BUFF_OF[key]
          return false unless buff && me.effect_active?(buff)

          return me.buff_time_left(buff) <= (m[1].to_i / 60.0)
        end
        if (m = mod.match(EMPOWERED))
          # 5.16 (4336): skip when an Empowered buff of +N or more is up
          bonus = me.buff_bonus(/^Empowered \(\+(\d+)\)/)
          strong = !bonus.nil? && bonus >= m[2].to_i
          return m[1].empty? ? strong : !strong
        end
        if (m = mod.match(THP))
          # 5.16 (4353): target HP percent from the Creature registry
          pct = creature_of(world, target)&.hp_percent
          return true if pct.nil?

          return m[1].empty? ? pct > m[2].to_i : pct <= m[2].to_i
        end
        if (m = mod.match(REPEAT))
          last = state.last_run(line.raw)
          return !last.nil? && (now - last) < m[1].to_i
        end
        if (m = mod.match(EFFECTS))
          return effects_skip?(m[1].upcase, /#{m[2]}/i, me)
        end

        word_skip?(mod.downcase, line, world, target, state)
      end

      def amount_skip?(key, amount, world, state, targets_policy)
        me = world.me
        neg = key.start_with?('!')
        base = key.delete_prefix('!')
        value = case base
                when 'e' then me.encumbrance_pct
                when 'essence' then me.shadow_essence
                when 'h' then me.health_pct
                when 'k' then return neg ? me.kneeling? : !me.kneeling?
                when 'm' then me.mana
                when 'mob' then return neg ? Targets.fightable_count(world.room.targets, targets_policy) > amount : Targets.fightable_count(world.room.targets, targets_policy) < amount
                when 's' then me.stamina
                when 'tier' then return neg ? state.unarmed_tier > amount : state.unarmed_tier < amount
                when 'v' then me.spirit
                when 'valid' then return neg ? Targets.candidates(world.room.targets, targets_policy).size > amount : Targets.candidates(world.room.targets, targets_policy).size < amount
                else return false
                end
        neg ? value >= amount : value < amount
      end

      def effects_skip?(kind, pattern, me)
        active = case kind.delete_prefix('!')
                 when 'ES' then me.spell_effect_active?(pattern)
                 when 'EB' then me.effect_active?(pattern)
                 when 'EC' then me.cooldown_active?(pattern)
                 when 'ED' then me.debuff_active?(pattern)
                 end
        kind.start_with?('!') ? active : !active
      end

      def creature_of(world, target)
        return nil if target.nil? || !world.respond_to?(:creature)

        world.creature(target.id)
      end

      def has_status?(world, target, name)
        c = creature_of(world, target)
        c ? (c.has_status?(name) ? true : false) : false
      end

      def crtr_flag?(world, target, flag)
        c = creature_of(world, target)
        c ? (c.crtr_flag?(flag) ? true : false) : false
      end

      def prone?(world, target)
        c = creature_of(world, target)
        c ? PRONE_STATUSES.any? { |st| c.has_status?(st) } : false
      end

      def word_skip?(word, line, world, target, state)
        me = world.me
        neg = word.start_with?('!')
        base = word.delete_prefix('!')
        if (buff = BUFF_WORDS[base])
          active = buff.is_a?(Integer) ? me.spell_active?(buff) : me.effect_active?(buff)
          return neg ? !active : active
        end

        want = case base
               when 'burst' then neg ? me.cooldown_active?('Burst of Swiftness') : !me.buff_matching?(/Enh\. Dexterity/)
               when 'surge' then neg ? me.cooldown_active?('Surge of Strength') : !me.buff_matching?(/Enh\. Strength/)
               when 'bearhug' then (me.effect_active?('Enh. Strength (+10)') || me.effect_active?('Enh. Strength (+20)')) ^ !neg
               when 'voidweaver' then me.buff_matching?(/Voidweaver/) ^ neg
               when 'disease' then me.diseased? ^ !neg
               when 'poison' then me.poisoned? ^ !neg
               when 'hidden' then me.hidden? ^ !neg
               when 'outside' then (world.room.respond_to?(:outside?) ? world.room.outside? : false) ^ !neg
               when 'ancient' then ((target.name.to_s =~ /^(?:grizzled|ancient) / && target.name != 'ancient ghoul master') ? true : false) ^ !neg
               when 'flying' then has_status?(world, target, 'flying') ^ !neg
               when 'frozen' then has_status?(world, target, 'immobilized') ^ neg
               when 'noncorporeal' then target.type.to_s.split(',').include?('noncorporeal') ^ !neg
               when 'undead' then target.type.to_s.split(',').include?('undead') ^ !neg
               when 'prone' then prone?(world, target) ^ neg
               when 'rooted' then has_status?(world, target, 'rooted') ^ neg
               when *STATUS_WORDS then has_status?(world, target, base) ^ !neg
               when *FLAG_WORDS then crtr_flag?(world, target, base.to_sym) ^ !neg
               when 'wounded' then (creature_of(world, target)&.low_hp?(25) ? true : false) ^ !neg
               when 'fatalcrit' then (creature_of(world, target)&.fatal_crit? ? true : false) ^ !neg
               when 'smote' then (creature_of(world, target)&.smote? ? true : false) ^ !neg
               when 'ucsdecent' then (creature_of(world, target)&.ucs_position == 1) ^ !neg
               when 'ucsgood' then (creature_of(world, target)&.ucs_position == 2) ^ !neg
               when 'ucsexcellent' then (creature_of(world, target)&.ucs_position == 3) ^ !neg
               when 'ucstierup' then creature_of(world, target)&.ucs_tierup.nil? ^ neg
               when 'tier1', 'tier2', 'tier3' then (state.unarmed_tier == base[-1].to_i) ^ !neg
               when 'once' then state.done_once?(target.id, line.raw)
               when 'room' then state.done_in_room?(line.raw)
               when 'splashy' then (world.room.respond_to?(:tags) && Array(world.room.tags).include?('meta:splashy')) ^ neg
               when 'pcs' then (Array(world.room.players).map(&:noun) - world.group_nouns).any? ^ !neg
               when 'justice' then neg ? state.swift_justice >= 1 : state.swift_justice.zero?
               when 'reflex' then state.arcane_reflex ^ !neg
               when 'censer', 'repeatdelay', 'buff', 'afterattack' then false
               else false
               end
        want ? true : false
      end
    end

    # bigshot 5.16's coup de grace gate (cmd_cmans 4990, npc_coup_ready?
    # 8371): re-test the skill's requirement at the moment of send and
    # hold the coup rather than spend 20 stamina on a refusal. The
    # requirement (at or below rank*10% HP incapacitated, rank*5%
    # otherwise, 200 HP cap) is Lich's CreatureInstance#coup_eligible?.
    # A target without creature or HP data passes through.
    module Coup
      module_function

      def rank
        ::Lich::Gemstone::CMan['coupdegrace'].to_i
      rescue StandardError
        0
      end

      # @return [Symbol, nil] :coup_not_ready, or nil to send
      def hold_reason(world, target, rank: self.rank)
        return nil unless rank.positive?

        c = world.respond_to?(:creature) ? world.creature(target&.id) : nil
        return nil if c.nil?

        return nil unless c.current_hp && c.max_hp && c.max_hp.positive?

        c.coup_eligible?(rank) ? nil : :coup_not_ready
      end
    end

    # cmd_spell's gates (4867-4907) as a reason, or nil to cast.
    module SpellGates
      SHORT_BUFFS = [140, 211, 215, 219, 919, 1619, 1650].freeze
      SELF_OK_WHEN_OOM = [9605, 506, 902, 411].freeze

      module_function

      def reason(world, num, target, state, _policy)
        me = world.me
        s = world.spell[num]
        return :unknown_spell if s.nil? || !s.known?
        return :penalty_597 if me.spell_active?(597) && s.mana_cost.to_i.positive? && s.mana_cost.to_i + 5 > me.mana
        return :active if num == 506 && s.active?
        return :cooldown if num == 9605 && me.cooldown_active?('Surge of Strength')
        return :cooldown if num == 9625 && me.cooldown_active?('Burst of Swiftness')
        return :cooldown if num == 335 && me.cooldown_active?(335)
        return :hidden if num == 608 && me.hidden?
        return :once_per_target if num == 703 && target && state.cast_703.include?(target.id.to_s)
        return :once_per_target if num == 1614 && target && state.cast_1614.include?(target.id.to_s)
        return :target_gone if ![902, 411].include?(num) && target && target.status.to_s =~ /dead|gone/
        return :cooldown if num == 720 && me.cooldown_active?('Implosion')
        return :cooldown if SHORT_BUFFS.include?(num) && me.cooldown_active?(s.name)
        return :unaffordable unless s.affordable?

        nil
      end

      # bigshot 4903: unaffordable and not a self-buff that may wait means
      # "out of mana", the forced rest reason, unless oom is negative.
      def oom_rest?(num, policy) = !SELF_OK_WHEN_OOM.include?(num) && !policy.oom.to_i.negative?
    end
  end

  module Actions
    # TARGET #id: bigshot sets the game's target before a routine (6540)
    # and probes a creature it has not seen before (valid_target? 6928),
    # learning "untargetable" names it never tries again.
    class Target < Base
      ANSWERS = /^You are now targeting|^You can't target|^You discern that you are the origin|^You are unable to discern the origin|^What were you referring to\?/
      REFUSED = /^You can't target|^You discern that you are the origin|^You are unable to discern the origin/

      def initialize(world, target:, timeout: 3, **opts)
        super(world, target: target, **opts)
        @target = target
        @timeout = timeout
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        result = send_and_match("target ##{@target.id}", ANSWERS, timeout: @timeout)
        return result unless result.success?
        return Result.new(status: :failed, reason: :untargetable, line: result.line) if result.line =~ REFUSED
        return Result.new(status: :failed, reason: :referent_missing, line: result.line) if result.line =~ /What were you/

        result
      end
    end

    # wait_for_swing (5794): stand in the wander stance until the target
    # swings at us or a player (the Watch's :incoming_swing), the room
    # empties, the target goes prone, or the seconds run out.
    class WaitForSwing < Base
      def initialize(world, target:, seconds:, stance: nil, wander_stance: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @seconds = seconds.to_f
        @stance = stance
        @wander_stance = wander_stance
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        @stance&.call(@wander_stance) if @wander_stance && !Engage::Conditions.prone?(@world, @target)
        swung = false
        off = Events.on(:incoming_swing) { |e| swung = true if e.data[:target_id].to_s == @target.id.to_s }
        deadline = clock_now + @seconds
        until swung || clock_now > deadline || interrupted? || me.dead?
          break if Engage::Conditions.prone?(@world, @target)
          break unless target_still_live?

          sleep 0.25
        end
        Result.new(status: :success, reason: swung ? :swung : :waited)
      ensure
        Events.off(off) if off && Events.respond_to?(:off)
      end
    end

    # AMBUSH / ATTACK at a body part from the profile's ambush list
    # (cmd_ambush 5479): a refused part moves to the next, roundtime
    # resets to the first.
    class Ambush < Base
      include CombatRt

      DEFAULT_PARTS = ['head', 'right leg', 'left leg', 'chest'].freeze
      ANSWERS = /round(?:time)?|You cannot aim that high!|does not have a head!|is already missing that!|does not have a .* leg!|does not have a .* arm!|^What were you referring to\?/i
      REFUSED = /You cannot aim that high!|does not have a head!|is already missing that!|does not have a (?:right|left) leg!|does not have a (?:right|left) arm!/i

      def initialize(world, target:, parts: [], cursor:, timeout: 2, **opts)
        super(world, target: target, **opts)
        @target = target
        @parts = parts.empty? ? DEFAULT_PARTS : parts
        @cursor = cursor
        @timeout = timeout
      end

      attr_reader :cursor

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform
        tries = 0
        loop do
          @cursor = 0 if @cursor >= @parts.size
          verb = me.hidden? ? 'ambush' : 'attack'
          result = send_and_match("#{verb} ##{@target.id} #{@parts[@cursor]}", ANSWERS, timeout: @timeout)
          return result unless result.success?

          if result.line =~ REFUSED
            @cursor += 1
            tries += 1
            return Result.new(status: :failed, reason: :no_part_left, line: result.line) if tries > @parts.size
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            next
          end
          @cursor = 0
          return result
        end
      end
    end
  end

  module Behaviors
    # One routine line per tick.
    class Engage < Behavior
      attr_reader :target, :state, :cursor, :policy, :targets_policy, :mstrike_policy, :stance

      VERBS = /^(?:attack|kill|jab|punch|kick|grapple|hurl)\b/
      STANCE_FREE = /^(?:\d+|wait|sleep|wand|berserk|script|hide|nudgeweapon)/i
      WEEDS = /\b(?:vine|bramble|widgeonweed|vathor club|swallowwort|smilax|creeper|briar|ivy|tumbleweed)\b/
      SPELL = /^(incant)?\s?(\d+)\s?((?:open|closed)?\s?(?:cast|channel|evoke)?\s?(?:cast|channel|evoke)?\s?(?:open|closed)?\s?(?:acid|air|cold|earth|fire|lightning|steam|water)?)?.*$/i
      ALLY_CAST = /^allycast\s+(\d+)\s+(.+)$/i
      # Words that Routines (routines.rb) handles; fire has its aim there too
      UNSUPPORTED = /^(?:resonance|jewel|throw|wand|wandolier|unarmed|smite|caststop|unravel|barddispel|stomp|leech|rapid(?:fire)?|depress|phase|curse|efury|dhurl|briar|assume|wield|store|tether|sacrifice|nudgeweapons?|berserk|force|eachtarget|dislodge|fire|celerity|haste|506|slayer|240|tonis|1035)\b/i

      # @param policy [Engage::Policy]
      # @param targets_policy [Targets::Policy]
      # @param wander_policy [Wander::Policy] for the claim
      # @param mstrike_policy [Actions::Mstrike::Policy]
      # @param maintain_state [Maintain::State] for the stamina top-up
      # @param scripts [#start, #running?, #kill]
      # @param stance [#call] (name) -> Boolean
      # @param group [Group::Leader, nil] the followers to order to attack
      # @param fried [#call] -> Boolean, for disable_commands in a group
      def initialize(policy:, targets_policy:, wander_policy: EO::Engine::Wander::Policy.new, mstrike_policy: Actions::Mstrike::Policy.new,
                     state: EO::Engine::Engage::State.new, maintain_state: EO::Engine::Maintain::State.new, scripts: nil, stance: nil,
                     group: nil, fried: nil, clock: Time)
        super()
        @policy = policy
        @targets_policy = targets_policy
        @wander_policy = wander_policy
        @mstrike_policy = mstrike_policy
        @state = state
        @maintain_state = maintain_state
        @scripts = scripts || EO::Engine::Behaviors::Rest::LichScripts
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @group = group
        @fried = fried || -> { false }
        @attack_ordered_at = nil
        @called_at = nil
        @clock = clock
        @target = nil
        @routine = []
        @cursor = 0
        @ambush_cursor = 0
        @unsupported = []
        @on_fight = nil
        Events.on(:entered_room) { |event| @state.new_room!(event.data[:room]); @target = nil }
        Events.on(:swift_justice) { |e| @state.swift_justice = e.data[:charges].to_i }
        Events.on(:unarmed_tier) { |e| @state.unarmed_tier = e.data[:tier].to_i }
        Events.on(:bolted) { @state.bolted! }
        Events.on(:weapon_reaction) { |e| @state.reaction = e.data[:reaction] }
        Events.on(:arcane_reflex) { |e| @state.arcane_reflex = e.data[:active] }
        Events.on(:smote) { |e| e.data[:smote] ? (@state.smite_done? << e.data[:id].to_s) : @state.smite_done?.delete(e.data[:id].to_s) }
        Events.on(:haze_703) { |e| e.data[:on] ? (@state.cast_703 << e.data[:id].to_s) : @state.cast_703.delete(e.data[:id].to_s) }
        Events.on(:rebuke_1614) { |e| e.data[:on] ? (@state.cast_1614 << e.data[:id].to_s) : @state.cast_1614.delete(e.data[:id].to_s) }
        Events.on(:arrow_stuck) { |e| @state.archery_stuck << e.data[:where]; @state.dislodge_locations << e.data[:where]; @state.dislodge_target = e.data[:id] }
        Events.on(:aiming) { |e| @state.archery_location = e.data[:where] }
        Events.on(:bond_return) { @state.bond_returned = true }
        Events.on(:unarmed_followup) { |e| @state.unarmed_followup = true; @state.unarmed_followup_attack = e.data[:attack] }
        Events.on(:ally_attacked) { |e| @state.ally_attacked!(e.data[:name]) }
      end

      # eachtarget swaps the creature for one line (cmd_eachtarget 4220).
      def retarget(creature) = @target = creature

      def priority = 50

      # Called with a block when a fight begins in a room (Flee's
      # lone_targets_only rule).
      def on_fight(&block) = @on_fight = block

      def wants_control?(world)
        return false unless EO::Engine::Wander::Predicates.claim_ours?(world, @wander_policy)
        return false if @state.combat_blocked_room.to_s == world.room.id.to_s

        !next_target(world).nil?
      end

      def tick(world)
        # bigshot check_boons: the ASSESS a boon creature needs before the
        # ignore and flee rules can judge it, sent now that we hold the
        # tick (never from a predicate, where a trip may still be walking)
        assessment = assess_boons(world)
        return assessment if assessment

        creature = next_target(world)
        return Actions::Result.new(status: :failed, reason: :no_target) if creature.nil?

        if creature != @target
          switch_to(creature, world)
          probe = ensure_targeted(world)
          return probe if probe && !probe.success?
        end
        @on_fight&.call
        called = call_followers(world)
        return called if called
        return Actions::Result.new(status: :failed, reason: :no_routine) if @routine.empty?

        line = @routine[@cursor]
        @cursor = (@cursor + 1) % @routine.size
        run_line(world, line)
      end

      private

      ATTACK_ORDER_EVERY = 10 # do_hunt 7383: a new target, or every ten seconds
      CALL_BACK_EVERY = 10

      def grouped? = !@group.nil? && !@group.solo?

      # One pending boon assessment in this room, as the tick's action.
      def assess_boons(world)
        cache = @targets_policy.boon_abilities
        return nil unless cache.respond_to?(:next_pending)

        creature = cache.next_pending(world.room.targets)
        creature && cache.assess!(creature)
      end

      # find_target with priority (7010, 6991) over the fightable, wanted
      # creatures the game has not refused.
      def next_target(world)
        Targets.choose(world.room.targets, @targets_policy, current: @target, priority: @policy.priority)
      end

      # find_routine (7177): the creature's letter, quick_commands in
      # quick mode; disable_commands for a fried member of a group (7181).
      def switch_to(creature, world)
        @target = creature
        letter = @policy.quick ? 'quick' : Targets.routine_for(creature, @targets_policy)
        list = if grouped? && @fried.call && Array(@policy.disable_commands).any?
                 letter = 'disabled'
                 @policy.disable_commands
               else
                 @policy.routine_for(letter)
               end
        @routine = EO::Engine::Engage::Routine.parse(list)
        @cursor = 0
        @ambush_cursor = 0
        Events.emit(:engaged, target: creature.id, name: creature.name, routine: letter)
        order_attack(world)
      end

      def order_attack(world)
        return unless grouped?

        @attack_ordered_at = @clock.now
        @group.order(:attack, room: world.room.id)
      end

      # attack 7780-7792: the followers told to attack (again every ten
      # seconds), and a missing one called back: group open, unhide,
      # follow_now, without stopping the fight.
      def call_followers(world)
        return nil unless grouped?

        order_attack(world) if @attack_ordered_at.nil? || @clock.now - @attack_ordered_at >= ATTACK_ORDER_EVERY
        return nil if @group.all_present?(world)
        return nil if @called_at && @clock.now - @called_at < CALL_BACK_EVERY

        @called_at = @clock.now
        Events.emit(:waiting_for_followers, reason: :follower_missing, room: world.room.id)
        @group.order(:follow_now, room: world.room.id)
        Actions::GroupOpen.new(world).call
        Actions::Command.new(world, command: 'unhide').call if world.me.hidden?
        Actions::Result.new(status: :success, reason: :called_back)
      end

      # TARGET #id when the game is not already on it; a refusal teaches
      # the name (valid_target? 6928-6934) and drops the creature.
      def ensure_targeted(world)
        return nil if world.me.current_target_id.to_s == @target.id.to_s

        result = Actions::Target.new(world, target: @target).call
        if result.failed? && result.reason == :untargetable
          # Another group member can kill the creature while TARGET is in
          # flight. The game then answers "You can't target ...", but that
          # is a transient dead-target race, not evidence that every creature
          # with this name is intrinsically untargetable. Match Bigshot's
          # post-probe dead/gone guard before persisting the species name.
          if @target.status.to_s =~ /dead|gone/
            @target = nil
            return Actions::Result.new(status: :skipped, reason: :target_gone, line: result.line)
          end

          @targets_policy.untargetable_set << @target.name unless @targets_policy.untargetable_set.include?(@target.name)
          @state.untargetable_learned << @target.name
          Events.emit(:untargetable_learned, name: @target.name)
          @target = nil
        end
        result
      end

      def run_line(world, line)
        blocked = EO::Engine::Engage::Conditions.blocked_by(line, world, @target, @state, @targets_policy, now: @clock.now)
        return Actions::Result.new(status: :skipped, reason: :condition, line: blocked) if blocked

        text = line.text.gsub(/\btarget\b/, "##{@target.id}")
        soothe(world)
        reaction(world)
        @stance.call(@policy.hunting_stance) if @policy.hunting_stance && text !~ STANCE_FREE
        result = dispatch(world, text, line)
        if result&.failed? && result.reason == :blocked
          @state.combat_blocked_room = world.room.id
          Events.emit(:combat_blocked, room: world.room.id, target: @target&.id)
        end
        @state.register(@target.id, line.raw, @clock.now) if result && !(result.failed? && result.reason == :condition)
        result
      end

      public

      def dispatch(world, text, line)
        case text
        when ALLY_CAST then ally_spell(world, Regexp.last_match(1).to_i, Regexp.last_match(2), line)
        when SPELL then spell(world, Regexp.last_match(1), Regexp.last_match(2).to_i, Regexp.last_match(3).to_s.strip)
        when /^mstrike\b\s*(.*)$/ then mstrike(world, Regexp.last_match(1))
        when /^hide\s?(\d+)?/ then Actions::Hide.new(world, attempts: Regexp.last_match(1).to_i.zero? ? 3 : Regexp.last_match(1).to_i).call
        when /^(k?)weed\b/ then weed(world, Regexp.last_match(1) == 'k')
        when /^script\s+(.*?)(?:\s|$)(.*)/ then run_script(Regexp.last_match(1), Regexp.last_match(2))
        when /^sleep\s+(\d+)( nostance)?/
          @stance.call(@policy.wander_stance) unless Regexp.last_match(2)
          sleep Regexp.last_match(1).to_i
          Actions::Result.new(status: :success, reason: :slept)
        when /^stance\s+(.*)/ then Actions::Result.new(status: @stance.call(Regexp.last_match(1)) ? :success : :failed, reason: :stance)
        when /^wait\s+(\d+)/
          Actions::WaitForSwing.new(world, target: @target, seconds: Regexp.last_match(1).to_i, stance: @stance, wander_stance: @policy.wander_stance).call
        when /^ambush\s?(.*)?/
          parts = Regexp.last_match(1).to_s.empty? ? Array(@policy.ambush) : [Regexp.last_match(1)]
          action = Actions::Ambush.new(world, target: @target, parts: parts, cursor: @ambush_cursor)
          result = action.call
          @ambush_cursor = action.cursor
          result
        when /^shield (?:bash|charge|pin|push|strike|throw|trample)\b|^(?:shout|yowlp|holler|bellow|growl|cry)\b/
          maneuver(world, text)
        when UNSUPPORTED then EO::Engine::Engage::Routines.run(self, world, text, line) || unsupported(line)
        when VERBS then Actions::Attack.new(world, target: @target, command: text).call
        else
          # a routine may name the category ("cman bullrush"); bigshot's
          # words are the bare technique
          words = text.split
          words.shift if %w[cman weapon feat shield warcry].include?(words.first) && words.size > 1 && text !~ /^shield /
          if Actions::Maneuver::WORDS.key?(words.first)
            maneuver(world, words.join(' '))
          else
            Actions::Command.new(world, command: text).call
          end
        end
      end

      def maneuver(world, text)
        word = text =~ /^shield \w+/ ? text[/^shield \w+/] : text.split.first
        all = text.split.include?('all')
        pair = Actions::Maneuver.resolve(word)
        return unsupported(Line.new(raw: text, text: text, modifiers: [])) if pair.nil?

        category, name = pair
        if name == 'Coup de Grace'
          held = EO::Engine::Engage::Coup.hold_reason(world, @target)
          return Actions::Result.new(status: :failed, reason: held) if held
        end
        target = if all then 'all'
                 elsif %w[burst surge].include?(word) then nil
                 elsif category == :warcry && %w[shout yowlp holler].include?(word) then nil
                 else @target
                 end
        Actions::Maneuver.new(world, category: category, name: name, target: target, skip_if_buff: %w[burst surge].include?(word)).call
      end

      # cmd_spell (4867): the gates, then wand or wrack when unaffordable,
      # else the out-of-mana rest reason; then Cast.
      def spell(world, incant, num, extra)
        reason = EO::Engine::Engage::SpellGates.reason(world, num, @target, @state, @policy)
        if reason == :unaffordable
          # 5882: cmd_wand in the spell's place, its result the line's
          return Actions::Wand.new(world, target: @target, policy: @policy, state: @state, stance: @stance).call if @policy.wand_if_oom

          Actions::Wrack.new(world, policy: EO::Engine::Maintain::Policy.new(use_wracking: true)).call if @policy.use_wracking
          unless world.spell[num].affordable?
            Events.emit(:out_of_mana, spell: num) if EO::Engine::Engage::SpellGates.oom_rest?(num, @policy)
            return Actions::Result.new(status: :failed, reason: :out_of_mana)
          end
        elsif reason
          return Actions::Result.new(status: :failed, reason: reason)
        end

        target = [506, 902, 411].include?(num) ? nil : @target
        result = Actions::Cast.new(world, spell: num, target: target, extra: extra.empty? ? nil : extra, incant: !incant.nil?).call
        if result.success?
          @state.cast_703 << @target.id.to_s if num == 703
          @state.cast_1614 << @target.id.to_s if num == 1614
          @stance.call(@policy.hunting_stance) if incant && @policy.hunting_stance
        end
        result
      end

      # A support spell on a named member of our current in-game group.
      # Resolve the profile's case-insensitive name against both the group
      # and room rosters, then preserve the game's canonical spelling.
      def ally_spell(world, num, requested_name, line)
        group_name = Array(world.group_nouns).map(&:to_s).find { |name| name.casecmp?(requested_name.to_s) }
        player = Array(world.room.players).find do |candidate|
          [candidate.respond_to?(:noun) ? candidate.noun : nil,
           candidate.respond_to?(:name) ? candidate.name : nil].compact.any? { |name| name.to_s.casecmp?(requested_name.to_s) }
        end
        return Actions::Result.new(status: :skipped, reason: :ally_missing) unless group_name && player

        name = player.respond_to?(:noun) && !player.noun.to_s.empty? ? player.noun.to_s : group_name
        after_attack = line.modifiers.any? { |modifier| modifier.casecmp?('afterattack') }
        if after_attack && !@state.ally_cast_ready?(line.raw, name)
          return Actions::Result.new(status: :skipped, reason: :awaiting_ally_attack)
        end

        result = Actions::Cast.new(world, spell: num, target: name).call
        @state.ally_cast_done!(line.raw, name) if after_attack && result.success?
        result
      end

      # cmd_weed (4797): Tangleweed (610) at the target, evoked for kweed,
      # unless a vine or weed is already on the floor.
      def weed(world, evoke)
        return Actions::Result.new(status: :failed, reason: :weed_present) if Array(world.room.loot).any? { |o| o.name.to_s =~ WEEDS }

        Actions::Cast.new(world, spell: 610, target: @target, extra: evoke ? 'evoke' : nil).call
      end

      def mstrike(world, attack)
        floor = @mstrike_policy.stamina_cooldown || @mstrike_policy.stamina_quickstrike
        top_up = EO::Engine::Maintain::Stamina.top_up_spell(world, floor: floor || world.me.max_stamina, state: @maintain_state, now: @clock.now)
        if top_up
          @maintain_state.adrenal_at = @clock.now if top_up == 1107
          Actions::Cast.new(world, spell: top_up).call
        end
        Actions::Mstrike.new(world, policy: @mstrike_policy, target: @target, attack: attack.to_s.empty? ? nil : attack, targets_policy: @targets_policy).call
      end

      # cmd 3318: a kick while held in place is a punch
      def kick_to_punch(text) = @state.respond_to?(:rooted) && @state.rooted ? text.gsub(/\bkick\b/i, 'punch') : text

      # cmd 3348: the Minor Mental soothe when a rage or a song holds us
      def soothe(world)
        s = world.spell[1201]
        return unless s&.known? && s.affordable?
        return unless [201, 216, 1015, 1016, 1108, 1120].any? { |n| world.me.spell_active?(n) }

        s.cast
      end

      # perform_reaction (8062) before the command when the game offered one
      def reaction(world)
        return unless @policy.weapon_reaction && @state.reaction

        Actions::Reaction.new(world, reaction: @state.reaction, stance: @stance, hunting_stance: @policy.hunting_stance).call
        @state.reaction = nil
      end

      private

      # cmd_run_script (5458): run it and wait for it, a tick at a time
      # would be better; bigshot blocks and so does this until Travel.
      def run_script(name, args)
        if @scripts.running?(name)
          @scripts.kill(name)
          20.times { break unless @scripts.running?(name); sleep 0.1 }
        end
        @scripts.start(name, args.to_s.empty? ? nil : args)
        200.times { break unless @scripts.running?(name); sleep 0.25 }
        Actions::Result.new(status: :success, reason: :script_ran)
      end

      def unsupported(line)
        unless @unsupported.include?(line.text)
          @unsupported << line.text
          Events.emit(:routine_unsupported, command: line.text)
        end
        Actions::Result.new(status: :failed, reason: :unsupported, line: line.text)
      end
    end
  end
end

# wait_for_swing (5806): a creature's line that ends on us. Player names
# are M3's; the room description is excluded the way bigshot excludes it.
