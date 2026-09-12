# frozen_string_literal: true

# ============================================================================
# maneuvers (bigshot's cmd_cmans / cmd_weapons / cmd_shields / cmd_feats /
#            cmd_rogue_cmans / cmd_warrior_shouts / cmd_assault / cmd_mstrike)
# ============================================================================

#
# Techniques are Lich's data: what a technique is called, what it costs,
# whether it is known, on cooldown or affordable, the command it is sent
# with and the lines that answer it all come from the PSM readers (CMan,
# Weapon, Shield, Feat, Warcry: .known? .affordable? .available?
# .buff_active? .command .results_regex, lich-5 #1583). The engine adds
# what bigshot's cmd_* routines add on top: the gate order, the target,
# the timeout per kind, the one swap on a bow in the wrong hand, and a
# name for every refusal. Rules and bigshot line references in
# hunting-engine-plan.md, "Maneuvers".
#
module EO::Engine
  module Actions
    # One technique at a creature, or at nothing (BURST, a warcry ALL).
    #
    #   Maneuver.new(world, category: :cman, name: 'Bull Rush', target: creature).call
    #   Maneuver.new(world, category: :weapon, name: 'Barrage', target: creature).call
    #   Maneuver.new(world, category: :warcry, name: 'bellow', target: 'all').call
    #   Maneuver.new(world, category: :cman, name: 'Burst of Swiftness', skip_if_buff: true).call
    class Maneuver < Base
      include CombatRt

      # The technique kinds, one per PSM reader.
      CATEGORIES = %i[cman weapon shield feat warcry].freeze
      # The parts of Lich's Status.muckled? apart from dead, as Me readers, for
      # the recovery techniques that escape some of them.
      MUCKLED = { webbed: :webbed?, bound: :bound?, stunned: :stunned?, sleeping: :sleeping? }.freeze

      # bigshot's routine words, as its cmd dispatch and the
      # commands hashes in each cmd_* routine name them, to the reader and
      # the technique. Engage's routine compiler reads this table; it is
      # here because it is the maneuver vocabulary bigshot profiles speak.
      WORDS = {
        # cmd_assault 3790
        'barrage'        => [:weapon, 'Barrage'],
        'flurry'         => [:weapon, 'Flurry'],
        'fury'           => [:weapon, 'Fury'],
        'gthrusts'       => [:weapon, 'Guardant Thrusts'],
        'pummel'         => [:weapon, 'Pummel'],
        'thrash'         => [:weapon, 'Thrash'],
        # cmd_weapons 3885
        'charge'         => [:weapon, 'Charge'],
        'clash'          => [:weapon, 'Clash'],
        'cripple'        => [:weapon, 'Cripple'],
        'cyclone'        => [:weapon, 'Cyclone'],
        'dizzyingswing'  => [:weapon, 'Dizzying Swing'],
        'pindown'        => [:weapon, 'Pin Down'],
        'pulverize'      => [:weapon, 'Pulverize'],
        'twinhammer'     => [:weapon, 'Twin Hammerfists'],
        'volley'         => [:weapon, 'Volley'],
        'wblade'         => [:weapon, 'Whirling Blade'],
        'whirlwind'      => [:weapon, 'Whirlwind'],
        # cmd_shields 3956
        'shield bash'    => [:shield, 'Shield Bash'],
        'shield charge'  => [:shield, 'Shield Charge'],
        'shield pin'     => [:shield, 'Shield Pin'],
        'shield push'    => [:shield, 'Shield Push'],
        'shield strike'  => [:shield, 'Shield Strike'],
        'shield throw'   => [:shield, 'Shield Throw'],
        'shield trample' => [:shield, 'Shield Trample'],
        # cmd_cmans 4151
        'bullrush'       => [:cman, 'Bull Rush'],
        'coupdegrace'    => [:cman, 'Coup de Grace'],
        'cpress'         => [:cman, 'Crowd Press'],
        'dirtkick'       => [:cman, 'Dirtkick'],
        'disarm'         => [:cman, 'Disarm Weapon'],
        'exsanguinate'   => [:cman, 'Exsanguinate'],
        'feint'          => [:cman, 'Feint'],
        'gkick'          => [:cman, 'Groin Kick'],
        'hamstring'      => [:cman, 'Hamstring'],
        'haymaker'       => [:cman, 'Haymaker'],
        'headbutt'       => [:cman, 'Headbutt'],
        'kifocus'        => [:cman, 'Ki Focus'],
        'leapattack'     => [:cman, 'Leap Attack'],
        'mblow'          => [:cman, 'Mighty Blow'],
        'sattack'        => [:cman, 'Spin Attack'],
        'sbash'          => [:cman, 'Shield Bash'],
        'sblow'          => [:cman, 'Staggering Blow'],
        'scleave'        => [:cman, 'Spell Cleave'],
        'sthieve'        => [:cman, 'Spell Thieve'],
        'sunder'         => [:cman, 'Sunder Shield'],
        'tackle'         => [:cman, 'Tackle'],
        'trip'           => [:cman, 'Trip'],
        'truestrike'     => [:cman, 'True Strike'],
        'vaultkick'      => [:cman, 'Vault Kick'],
        # cmd_bearhug 4353
        'bearhug'        => [:cman, 'Bearhug'],
        # cmd_rogue_cmans 4413
        'cutthroat'      => [:cman, 'Cutthroat'],
        'divert'         => [:cman, 'Divert'],
        'shroud'         => [:cman, 'Dust Shroud'],
        'eviscerate'     => [:cman, 'Eviscerate'],
        'eyepoke'        => [:cman, 'Eyepoke'],
        'footstomp'      => [:cman, 'Footstomp'],
        'garrote'        => [:cman, 'Garrote'],
        'kneebash'       => [:cman, 'Kneebash'],
        'mug'            => [:cman, 'Mug'],
        'nosetweak'      => [:cman, 'Nosetweak'],
        'subdue'         => [:cman, 'Subdue'],
        'spunch'         => [:cman, 'Sucker Punch'],
        'sweep'          => [:cman, 'Sweep'],
        'swiftkick'      => [:cman, 'Swiftkick'],
        'templeshot'     => [:cman, 'Templeshot'],
        'throatchop'     => [:cman, 'Throatchop'],
        # cmd_burst 5405, cmd_surge 5425 (self buffs, no target)
        'burst'          => [:cman, 'Burst of Swiftness'],
        'surge'          => [:cman, 'Surge of Strength'],
        # cmd_feats 4224
        'chastise'       => [:feat, 'Chastise'],
        'excoriate'      => [:feat, 'Excoriate'],
        # cmd_warrior_shouts 4458
        'shout'          => [:warcry, 'shout'],
        'yowlp'          => [:warcry, 'yowlp'],
        'holler'         => [:warcry, 'holler'],
        'bellow'         => [:warcry, 'bellow'],
        'growl'          => [:warcry, 'growl'],
        'cry'            => [:warcry, 'cry']
      }.freeze

      # Assaults run for several rounds: bigshot waits 10 s a read, 12 s in
      # all (cmd_assault 3809); bearhug up to five rounds, 16 and 17 s
      # (cmd_bearhug 4364); everything else 1 s a read, 2 s in all.
      # The reader's own names, not the routine words: default_timeout
      # compares against @name, which resolve() has already turned into
      # the long name. 'gthrusts' resolves to 'Guardant Thrusts', which
      # never matched the routine word, so the longest assault in the set
      # read for TIMEOUT (2 s) instead of ASSAULT_TIMEOUT (12 s) and
      # returned :no_confirmation while its rounds were still running.
      ASSAULTS = ['barrage', 'flurry', 'fury', 'guardantthrusts', 'pummel', 'thrash'].freeze
      # Seconds to read for any other technique.
      TIMEOUT = 2
      # Seconds to read for an assault (cmd_assault 3809).
      ASSAULT_TIMEOUT = 12
      # Seconds to read for a bearhug (cmd_bearhug 4364).
      BEARHUG_TIMEOUT = 17

      # Bigshot's complete_regex lines, named. The PSM readers' results
      # regex already matches the shared failures (PSMS::FAILURES_REGEXES)
      # and the technique's own result and roundtime; EXTRA adds the lines
      # bigshot waits on that the readers do not.
      REFUSALS = {
        referent_missing: /^What were you referring to\?|^I could not find what you were referring to\.|Could not find/i,
        already_dead: /already dead|little bit late/i,
        out_of_reach: /out of reach|^You can't reach/i,
        awkward: /awkward proposition|is lying down/i,
        too_injured: /too injured/i,
        muckled: /^You are still stunned\.$|^You don't seem to be able to move|still stunned/i,
        hidden: /^And give yourself away!  Never!$/,
        no_target: /^You do not currently have a target\.$/,
        hands_full: /^But your hands are full!$/,
        confused: /^Your mind clouds with confusion/,
        no_momentum: /^You lack the momentum/,
        unable: /^You are unable to do that right now\.$|can't manage to do that right now/,
        cooldown: /is still in cooldown\./i,
        mstrike_lockout: /may not be activated within 60 seconds of a Multi-Strike/i,
        wrong_hand: /Barrage can not be used with attack as the attack type/i,
        no_shield: /^You must be wielding a shield\./,
        no_weapon: /^You haven't learned how to disarm without a weapon!|is not holding a weapon\./,
        not_a_member: /^You must be an active member/,
        rooted: /rooted in place/i,
        unknown: / what\?$/i
      }.freeze

      # Every REFUSALS pattern as one Regexp, handed to the reader as its
      # results of interest.
      EXTRA = Regexp.union(*REFUSALS.values)

      # A routine word to [category, technique name]. 'shield bash' is the
      # CMan when it is known and the Shield technique otherwise (cmd_shields
      # 3967), the one word bigshot resolves at run time.
      #
      # @bigshot cmd_shields
      # @param word [String] a routine word such as 'bullrush' or 'shield bash'
      # @return [Array(Symbol, String), nil] [category, technique], or nil for
      #   a word WORDS does not know
      def self.resolve(word)
        key = word.to_s.downcase.strip
        return [:cman, 'Shield Bash'] if key == 'shield bash' && reader_for(:cman)&.known?('Shield Bash')

        WORDS[key]
      end

      # The Lich PSM reader for a category, looked up by name so the library
      # loads without them.
      #
      # @param category [Symbol] one of CATEGORIES
      # @return [Module, nil] Lich::Gemstone::CMan and kin, or nil when the
      #   category is unknown or the reader is not loaded
      def self.reader_for(category)
        name = { cman: 'CMan', weapon: 'Weapon', shield: 'Shield', feat: 'Feat', warcry: 'Warcry' }[category]
        return nil if name.nil?

        ::Lich::Gemstone.const_get(name)
      rescue NameError
        nil
      end

      # @param world [World]
      # @param category [Symbol] :cman, :weapon, :shield, :feat, :warcry
      # @param name [String] the technique as the reader knows it
      # @param target [#id, String, nil] a creature, a word such as 'all', or nothing
      # @param forcert_count [Integer] appends FORCERT when above 0 (never for assaults)
      # @param timeout [Numeric, nil] the read window; nil picks the kind's
      # @param ignore_cooldown [Boolean] CMan only: use during an ignorable cooldown
      #   (BURST at 60 stamina)
      # @param skip_if_buff [Boolean] refuse when the technique's buff is already up (burst, surge)
      # @param escapes [Array<Symbol>] the muckled conditions this technique
      #   is the recovery for (Escape Artist: webbed, bound); the muckled
      #   gate then refuses only the others, so the recovery can run while
      #   the character is in the state it removes
      # @param opts [Hash] passed through to Base
      def initialize(world, category:, name:, target: nil, forcert_count: 0, timeout: nil,
                     ignore_cooldown: false, skip_if_buff: false, escapes: [], **opts)
        super(world, target: target, **opts)
        @category = category.to_sym
        @name = name.to_s
        @target = target
        @forcert_count = forcert_count.to_i
        @timeout = timeout || default_timeout
        @ignore_cooldown = ignore_cooldown
        @skip_if_buff = skip_if_buff
        @escapes = Array(escapes).map(&:to_sym)
      end

      # bigshot's gate order, cmd_cmans 4179-4190: available (known and
      # not overexerted or cooling), affordable, the technique's own
      # cooldown; the buff check is cmd_burst's and cmd_surge's.
      #
      # @bigshot cmd_cmans
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :muckled if muckled?
        return :unknown_category unless CATEGORIES.include?(@category)

        r = reader
        return :no_reader if r.nil?
        return :unknown_technique unless r.known?(@name)
        return :buff_active if @skip_if_buff && r.buff_active?(@name)
        return :overexerted if me.debuff_active?('Overexerted')
        return :unaffordable unless r.affordable?(@name)
        return :cooldown unless available?(r)

        :ok
      end

      # The command the reader builds for the technique, its target and
      # the FORCERT count.
      #
      # @return [String, nil] nil when the category has no reader
      def command
        r = reader
        return nil if r.nil?

        r.command(warcry_word(r), target_argument, forcert_count: @forcert_count)
      end

      # CMan.command builds its word from the table's :usage field, but
      # Warcry.command has no usage table and sends PSMS.name_normal(name)
      # as given (warcry.rb 208). A long name then goes on the wire as
      # `warcry seanettes_shout`, which the game does not recognise -
      # Maintain names the Shout that way (maintain.rb 647), so the one
      # warcry the engine sends on its own was the one that could not
      # land. bigshot sends the short word. Every other category already
      # resolves its own usage, so only :warcry is touched here.
      #
      # @return [String] the name to hand the reader
      def warcry_word(_r)
        return @name unless @category == :warcry

        short = ::Lich::Gemstone::PSMS.find_name(@name, 'Warcry')&.fetch(:short_name, nil)
        short.to_s.empty? ? @name : short
      rescue StandardError
        @name
      end

      # Send the technique and read for its result or a named refusal; a
      # bow in the wrong hand earns one swap and a second send.
      #
      # @return [Actions::Result] success on the technique's own result;
      #   failed with the refusal's key, :no_command or :interrupted
      def perform
        cmd = command
        return Result.new(status: :failed, reason: :no_command) if cmd.nil?

        regex = reader.results_regex(@name, results_of_interest: EXTRA)
        swapped = false
        loop do
          result = send_and_match(cmd, regex, timeout: @timeout)
          return result unless result.success?

          reason = REFUSALS.find { |_, rx| result.line =~ rx }&.first
          return result if reason.nil?

          # A bow in the wrong hand: swap once and send again (cmd_assault 3816).
          if reason == :wrong_hand && !swapped
            swapped = true
            swap = send_through_ladder('swap')
            return swap if swap.is_a?(Result)
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            next
          end

          return Result.new(status: :failed, reason: reason, line: result.line)
        end
      end

      private

      def reader = self.class.reader_for(@category)

      def available?(r)
        if @category == :cman
          r.available?(@name, ignore_cooldown: @ignore_cooldown)
        else
          r.available?(@name)
        end
      end

      # Lich's Status.muckled? minus the conditions this technique escapes:
      # the whole of it for an ordinary technique; for a recovery, each of
      # the other parts on its own (dead has its own gate).
      def muckled?
        return me.muckled? if @escapes.empty?

        MUCKLED.any? { |condition, reader| !@escapes.include?(condition) && me.respond_to?(reader) && me.public_send(reader) }
      end

      # A creature goes by id so the reader appends "#id"; a String ('all')
      # is sent as given; nothing sends the bare command.
      def target_argument
        return '' if @target.nil?
        return @target.id.to_i if @target.respond_to?(:id)

        @target.to_s
      end

      # An assault runs for a variable number of rounds - one, or five and
      # more - so its read is bounded by the technique, not by a guessed
      # span: Lich loops on the completion line with 12 s only as a
      # backstop (weapon.rb 309-320). Lich types these six :assault, which
      # is the authority; the names are the fallback when the table cannot
      # be read.
      def assault?
        return false unless @category == :weapon

        entry = ::Lich::Gemstone::PSMS.find_name(@name, 'Weapon')
        return true if entry && entry[:type] == :assault

        ASSAULTS.include?(@name.downcase.delete(' '))
      rescue StandardError
        ASSAULTS.include?(@name.downcase.delete(' '))
      end

      def default_timeout
        return BEARHUG_TIMEOUT if @name.downcase == 'bearhug'
        return ASSAULT_TIMEOUT if assault?

        TIMEOUT
      end
    end

    # MSTRIKE, focused at a creature or unfocused at the room, with bigshot's
    # cooldown and QUICKSTRIKE rules (cmd_mstrike 5162). Confirmed on the
    # game's mstrike start line from Lich's combat defs; bigshot sends it
    # bare and reads nothing.
    #
    #   Mstrike.new(world, policy: policy, target: creature).call
    #   Mstrike.new(world, policy: policy, target: creature, attack: 'jab').call   # UAC
    class Mstrike < Base
      include CombatRt

      # bigshot's mstrike_* settings: stamina floors default to
      # max stamina, so mstrike only ever fires at full stamina unless set.
      #
      # @bigshot mstrike settings
      Policy = Struct.new(:cooldown, :quickstrike, :stamina_cooldown, :stamina_quickstrike, :mob, keyword_init: true) do
        def initialize(cooldown: false, quickstrike: false, stamina_cooldown: nil, stamina_quickstrike: nil, mob: 2) = super
      end

      # MOC ranks at which a focused mstrike (one target) is allowed.
      FOCUSED_RANKS = 30
      # MOC ranks below which mstrike is refused outright.
      UNFOCUSED_RANKS = 5
      # A nest in the room: mstrike would hit it, so it is refused.
      NEST = /nest/i

      # Attack's refusals plus the mstrike-only ones.
      REFUSALS = Attack::REFUSALS.merge(
        no_stamina: /^You do not have enough stamina/,
        cooldown: /Multi-Strike is still in cooldown|still recovering from your last/i,
        no_moc: /Multi Opponent Combat/
      ).freeze

      # The start lines of Lich's :mstrike sequence (defs/sequences.rb).
      #
      # @return [Regexp] the union of the sequence's start patterns
      def self.start_regex
        @start_regex ||= begin
          defs = ::Lich::Gemstone::Combat::Definitions::Sequences::SEQUENCE_DEFS
          Regexp.union(defs.find { |d| d.name == :mstrike }.start_patterns)
        end
      end

      # @param world [World]
      # @param policy [Mstrike::Policy]
      # @param target [#id, nil] the creature for a focused mstrike
      # @param attack [String, nil] the UAC attack word (jab, punch, kick)
      # @param targets_policy [Targets::Policy, nil] for the crowd count
      # @param timeout [Numeric] seconds to wait for the game's answer
      # @param opts [Hash] passed through to Base
      def initialize(world, policy:, target: nil, attack: nil, targets_policy: nil, timeout: 3, **opts)
        super(world, target: target, **opts)
        @policy = policy
        @target = target
        @attack = attack
        @targets_policy = targets_policy || Targets::Policy.new
        @timeout = timeout
      end

      # bigshot's cmd_mstrike gates: dead, muckled, overexerted, too few
      # MOC ranks, a nest in the room, too small a crowd for an unfocused
      # strike, and the cooldown unless the policy lets stamina override it.
      #
      # @bigshot cmd_mstrike
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?
        return :overexerted if me.debuff_active?('Overexerted')
        return :no_moc if me.moc_ranks < UNFOCUSED_RANKS
        return :nest if roster.any? { |c| c.noun.to_s =~ NEST }
        return :too_few if !focused? && crowd < @policy.mob
        return :cooldown if me.cooldown_active?('Multi-Strike') && !(@policy.cooldown && me.stamina >= stamina_cooldown)

        :ok
      end

      # An unfocused (room-wide) strike: not enough ranks to focus, no
      # target, or a crowd at or above the policy's mob count.
      #
      # @return [Boolean]
      def unfocused? = !focused? || @target.nil? || crowd >= @policy.mob

      # QUICKSTRIKE is on and stamina is at or above its floor.
      #
      # @return [Boolean]
      def quickstrike? = @policy.quickstrike && me.stamina >= stamina_quickstrike

      # The text sent: "mstrike", the attack word, "#id" when focused,
      # wrapped in "quickstrike 1" when quickstriking.
      #
      # @return [String]
      def command
        base = ['mstrike', @attack].compact.join(' ')
        base += " ##{@target.id}" unless unfocused?
        quickstrike? ? "quickstrike 1 #{base}" : base
      end

      # Send the command and read for the mstrike start line or a refusal.
      #
      # @return [Actions::Result] success on the start line; failed with the
      #   refusal's key as the reason
      def perform
        result = send_and_match(command, Regexp.union(self.class.start_regex, *REFUSALS.values), timeout: @timeout)
        return result unless result.success?

        reason = REFUSALS.find { |_, rx| result.line =~ rx }&.first
        reason ? Result.new(status: :failed, reason: reason, line: result.line) : result
      end

      private

      def focused? = me.moc_ranks >= FOCUSED_RANKS

      def roster = Array(@world.room.targets)

      def crowd = Targets.fightable_count(roster, @targets_policy)

      def stamina_cooldown = @policy.stamina_cooldown || me.max_stamina

      def stamina_quickstrike = @policy.stamina_quickstrike || me.max_stamina
    end
  end
end
