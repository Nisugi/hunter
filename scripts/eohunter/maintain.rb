# frozen_string_literal: true

# ============================================================================
# maintain (bigshot's cast_signs, cmd_bless, wrack, check_902_411,
#           mstrike_spell_check)
# ============================================================================

#
# bigshot keeps its buffs up by calling cast_signs (7357) before every
# command, before every move and after every step, re-blesses a weapon
# the moment the game says its blessing wore off (cmd_bless 4629, from
# hunt_monitor's two lines), and wracks for mana when a sign or spell is
# unaffordable (wrack 5743). The engine's Maintain is that as a behavior
# at priority 40: one bless or one sign per tick, with every gate bigshot
# applies to each. Rules and bigshot line references in
# hunting-engine-plan.md, "Maintain".
#
module EO::Engine
  module Maintain
    # signs / bless / use_wracking / wracking_spirit / check_favor / ammo
    # from the profile (2875-2942).
    Policy = Struct.new(:signs, :bless, :use_wracking, :wracking_spirit, :check_favor, :ammo, keyword_init: true) do
      def initialize(signs: [], bless: false, use_wracking: false, wracking_spirit: 0, check_favor: false, ammo: nil) = super
    end

    # What Maintain learned about the wielded weapon and the blessings
    # still wanted; shared with the script so a rest can list them.
    class State
      attr_accessor :blessed_902, :blessed_411, :adrenal_at
      attr_reader :bless_wanted

      def initialize
        @blessed_902 = false
        @blessed_411 = false
        @bless_wanted = []
        @adrenal_at = nil
      end
    end

    # One entry of the profile's signs list, read the way cast_signs does.
    Sign = Struct.new(:entry, :kind, :num, :args, keyword_init: true)

    module Signs
      VOLN_SYMBOLS = [9903, 9904, 9905, 9906, 9907, 9908, 9909, 9910, 9912, 9913, 9914, 9918].freeze
      SHORT_BUFFS = [140, 211, 215, 219, 240, 919, 1619, 1650].freeze
      COOLDOWN_SKIPS = { 320 => 'Ethereal Censer', 605 => 'Barkskin' }.freeze
      FAVOR_COST = { 9805 => 0.1, 9806 => 0.1, 9816 => 0.5 }.freeze

      module_function

      def parse(entries)
        Array(entries).map do |raw|
          entry = raw.to_s.strip
          case entry
          when /\b650\s?(\w+)?\s?(\w+)?\s?/ then Sign.new(entry: entry, kind: :assume, num: 650, args: [Regexp.last_match(1), Regexp.last_match(2)])
          when /\b(?:515|rapid|rapidfire)(?:\s?\(?(\w+)\)?)?/ then Sign.new(entry: entry, kind: :rapid, num: 515, args: [Regexp.last_match(1)])
          when /^122420$/ then Sign.new(entry: entry, kind: :shout, num: 122420)
          when /^9605$/ then Sign.new(entry: entry, kind: :surge, num: 9605)
          when /^9625$/ then Sign.new(entry: entry, kind: :burst, num: 9625)
          when /^909$/ then Sign.new(entry: entry, kind: :channel, num: 909)
          when /^902$/ then Sign.new(entry: entry, kind: :bless_902, num: 902)
          when /^411$/ then Sign.new(entry: entry, kind: :bless_411, num: 411)
          else Sign.new(entry: entry, kind: :spell, num: entry.to_i)
          end
        end
      end

      # Why a sign is due now, or nil: :cast, :wrack (unaffordable and
      # wracking is on), :maneuver, :shout, :channel. cast_signs 7372-7490.
      #
      # @param renewal_cost [Integer] a Bard's song renewal cost, 0 otherwise
      def due(world, sign, policy, state, now: Time.now, renewal_cost: 0)
        me = world.me
        case sign.kind
        when :assume then assume_due?(world, sign) ? :assume : nil
        when :rapid then rapid_due?(world, sign) ? :cast : nil
        when :shout
          return nil unless me.buff_time_left('Empowered (+20)') <= (10 / 60.to_f)
          return nil if me.stamina < 25

          :shout
        when :surge then me.cooldown_active?('Surge of Strength') || me.stamina < 30 ? nil : :maneuver
        when :burst then me.cooldown_active?('Burst of Swiftness') || me.stamina < 30 ? nil : :maneuver
        when :channel
          s = world.spell[909]
          s && s.known? && s.affordable? && !s.active? ? :channel : nil
        when :bless_902 then state.blessed_902 ? nil : spell_ready?(world, 902) && :cast
        when :bless_411 then state.blessed_411 ? nil : spell_ready?(world, 411) && :cast
        else spell_due(world, sign.num, policy, now: now, renewal_cost: renewal_cost)
        end
      end

      # cast_signs 9127 hands "650 <aspect> <aspect|evoke>" to cmd_assume
      # every pass; its own early returns are the gate here: 650 known and
      # affordable, neither aspect up, not both on cooldown.
      def assume_due?(world, sign)
        me = world.me
        s = world.spell[650]
        return false unless s && s.known? && s.affordable?

        aspect, extra = sign.args.map { |a| a.to_s.capitalize }
        return false if me.effect_active?("Aspect of the #{aspect}") || me.effect_active?("Aspect of the #{extra}")
        return false if me.spell_active?("Aspect of the #{aspect} Cooldown") && me.spell_active?("Aspect of the #{extra} Cooldown")

        true
      end

      def rapid_due?(world, sign)
        me = world.me
        s = world.spell[515]
        return false unless s && s.known? && s.affordable?
        return false if me.effect_active?('Rapid Fire') && me.buff_time_left('Rapid Fire') > 0.05
        return false if me.cooldown_active?('Rapid Fire Recovery') && sign.args.first.to_s.empty?

        true
      end

      def spell_ready?(world, num)
        s = world.spell[num]
        s && s.known? && s.affordable?
      end

      def spell_due(world, num, policy, now:, renewal_cost:)
        me = world.me
        s = world.spell[num]
        return nil if s.nil? || !s.known?
        return nil if num == 9918
        return nil if VOLN_SYMBOLS.include?(num) && me.spell_active?(9012)

        cost = s.mana_cost.to_i
        # a five mana penalty while 597 is up (7373)
        return nil if me.spell_active?(597) && cost.positive? && cost + 5 > me.mana
        return nil if COOLDOWN_SKIPS[num] && me.cooldown_active?(COOLDOWN_SKIPS[num])
        return nil if num == 1035 && me.effect_active?('Song of Tonis')
        return nil if SHORT_BUFFS.include?(num) && me.cooldown_active?(s.name)
        return nil if s.active?

        if FAVOR_COST[num] && policy.check_favor
          favor_cost = ((2161 / 97) * me.level) - (5222 / 97)
          return nil if favor_cost * FAVOR_COST[num] > me.voln_favor
        end

        real_cost = cost > 1 ? cost : 0 # many erroneously return 1 (7479)
        return :wrack if !s.affordable? && real_cost > me.mana && policy.use_wracking
        return nil unless s.affordable?
        return nil if renewal_cost.positive? && me.mana < renewal_cost + cost
        return nil unless now > s.last_cast + 1.5

        :cast
      end
    end

    # mstrike_spell_check (5134): a Paladin or Empath tops stamina up before
    # an mstrike that its floor would refuse. Rejuvenation (1607) when its
    # estimated gain reaches the floor; Adrenal Surge (1107) once every 301
    # seconds when popped muscles are up or the estimated gain reaches it.
    module Stamina
      BLESSING_STEPS = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 66, 78, 91, 105, 120, 136, 153, 171, 190].freeze
      ADRENAL_INTERVAL = 301

      module_function

      # @return [Integer, nil] the spell to cast first, or nil
      def top_up_spell(world, floor:, state:, now: Time.now)
        me = world.me
        return nil unless me.profession.to_s =~ /Paladin|Empath/i

        floor = floor.to_i
        ranks = me.blessings_ranks
        rejuv = world.spell[1607]
        if rejuv && rejuv.known? && !rejuv.active? && rejuv.affordable? && me.stamina < floor
          bonus = BLESSING_STEPS.count { |n| ranks >= n }
          return 1607 if me.stamina + 15 + (bonus * 3) >= floor
        end

        adrenal = world.spell[1107]
        ready = state.adrenal_at.nil? || now >= state.adrenal_at + ADRENAL_INTERVAL
        return nil unless adrenal && adrenal.known? && adrenal.affordable? && !me.spell_active?(9010) && ready

        popped = me.spell_active?(9699)
        gain = if ranks >= 65 then me.max_stamina
               elsif ranks >= 35 then me.stamina + 50
               else me.stamina + 25
               end
        popped || gain >= floor ? 1107 : nil
      end
    end
  end

  module Actions
    # wrack (5743): Sign of Wracking when the spirit floor allows, else
    # Sigil of Power per fifty stamina, else Symbol of Mana off cooldown.
    # Each society reader (Lich::Gemstone::Society::CouncilOfLight,
    # GuardiansOfSunfist, OrderOfVoln) answers known?, affordable? and
    # available? and holds the command; their +use+ sends bare and reads
    # nothing, so the engine sends the same command itself and confirms
    # on mana rising.
    class Wrack < Base
      include CombatRt

      MAX_SIGILS = 4

      def initialize(world, policy:, timeout: 3, **opts)
        super(world, **opts)
        @policy = policy
        @timeout = timeout
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform
        if wracking_ready?
          confirm(command_for(col, 'wracking'), :wracking)
        elsif sunfist&.available?('power')
          last = nil
          MAX_SIGILS.times do
            break unless sunfist.available?('power')

            last = confirm(command_for(sunfist, 'power'), :sigil_of_power)
            break unless last.success?
          end
          last
        elsif voln&.available?('mana') && !me.cooldown_active?('Symbol of Mana')
          confirm(command_for(voln, 'mana'), :symbol_of_mana)
        else
          Result.new(status: :failed, reason: :no_wrack)
        end
      end

      private

      # bigshot 5746: the reader's affordable? already counts the spirit
      # the active dissipating signs still owe; wracking_spirit is the
      # profile's own floor, 9012 the lockout.
      def wracking_ready?
        col&.available?('wracking') && !me.spell_active?(9012) && me.spirit >= @policy.wracking_spirit.to_i
      end

      def command_for(reader, name)
        entry = reader[name] || {}
        entry[:usage] || "#{reader.name.split('::').last =~ /Voln/ ? 'symbol' : reader.name =~ /Sunfist/ ? 'sigil' : 'sign'} of #{entry[:short_name] || name}"
      end

      def confirm(command, reason)
        before = me.mana
        result = send_and_observe(command, timeout: @timeout) { me.mana > before }
        result.success? ? Result.new(status: :success, reason: reason) : result
      end

      # The seams: nil outside Lich or when the society module is absent.
      def col = society('CouncilOfLight')
      def sunfist = society('GuardiansOfSunfist')
      def voln = society('OrderOfVoln')

      def society(name)
        ::Lich::Gemstone::Society.const_get(name)
      rescue NameError
        nil
      end
    end

    # check_902_411 (7350): a quiet LOOK at the right hand tells whether
    # 902 ("gleams faintly with inner light") and 411 ("surrounded by a
    # scintillating") are already on it.
    class WeaponBlessCheck < Base
      GLEAMS = /gleams faintly with inner light/
      SCINTILLATING = /is surrounded by a scintillating/

      def initialize(world, state:, **opts)
        super(world, **opts)
        @state = state
      end

      def preconditions
        return :dead if me.dead?
        return :empty_hand if @world.hands.right.id.nil?

        :ok
      end

      def perform
        lines = look_at(@world.hands.right.id).join(' ')
        @state.blessed_902 = lines.match?(GLEAMS)
        @state.blessed_411 = lines.match?(SCINTILLATING)
        Result.new(status: :success, line: lines)
      end

      private

      def look_at(id)
        ::Lich::Util.quiet_command_xml("look at ##{id}", /You see nothing unusual\.|I could not find|The <a exist="(.*?)" noun=".*?">.*?<\/a>/)
      end
    end

    # cmd_bless (4629) for one item: 1604 at it, else 304 at it, else
    # SYMBOL BLESS, else there is no blessing and the hunt must stop.
    class Bless < Base
      include CombatRt

      ENFOLDS = /A violet tongue of flame enfolds the/

      def initialize(world, item_id:, **opts)
        super(world, **opts)
        @item_id = item_id.to_s
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform
        spell = @world.spell
        if spell[1604]&.known? && spell[1604].affordable?
          answer = spell[1604].cast("##{@item_id}", ENFOLDS)
          return Result.new(status: :success, reason: :spell_1604, line: answer.to_s) if answer.to_s =~ ENFOLDS
        end
        if spell[304]&.known? && spell[304].affordable?
          spell[304].cast("##{@item_id}")
          Result.new(status: :success, reason: :spell_304)
        elsif spell[9802]&.known?
          first = send_through_ladder("symbol bless ##{@item_id}")
          first.is_a?(Result) ? first : Result.new(status: :success, reason: :symbol_bless, line: first)
        else
          Result.new(status: :failed, reason: :no_blessing)
        end
      end
    end
  end

  module Behaviors
    # One bless or one sign per tick.
    class Maintain < Behavior
      attr_reader :state, :signs

      # @param policy [Maintain::Policy]
      # @param state [Maintain::State] shared with the script
      # @param renewal_cost [#call] -> Integer, a Bard's song renewal cost
      def initialize(policy:, state: EO::Engine::Maintain::State.new, renewal_cost: nil, clock: Time)
        super()
        @policy = policy
        @state = state
        @signs = EO::Engine::Maintain::Signs.parse(policy.signs)
        @renewal_cost = renewal_cost || -> { 0 }
        @clock = clock
        @due = nil
        install_watch
      end

      def priority = 40

      def wants_control?(world)
        @due = next_due(world)
        !@due.nil?
      end

      def tick(world)
        due = @due || next_due(world)
        return nil if due.nil?

        kind, subject = due
        case kind
        when :bless then bless(world, subject)
        when :wrack then Actions::Wrack.new(world, policy: @policy).call
        when :shout then Actions::Maneuver.new(world, category: :warcry, name: "Seanette's Shout").call
        when :maneuver then Actions::Maneuver.new(world, category: :cman, name: subject.kind == :surge ? 'Surge of Strength' : 'Burst of Swiftness').call
        when :channel
          world.spell[909].force_channel
          Actions::Result.new(status: :success, reason: :channel_909)
        when :cast then cast_sign(world, subject)
        when :assume then Actions::Assume.new(world, aspect: subject.args[0].to_s, extra: subject.args[1].to_s).call
        end
      end

      private

      def next_due(world)
        return [:bless, @state.bless_wanted.last] if @policy.bless && @state.bless_wanted.any?

        @signs.each do |sign|
          why = EO::Engine::Maintain::Signs.due(world, sign, @policy, @state, now: @clock.now, renewal_cost: @renewal_cost.call.to_i)
          return [why, sign] if why
        end
        nil
      end

      def bless(world, item_id)
        result = Actions::Bless.new(world, item_id: item_id).call
        if result.success?
          @state.bless_wanted.delete(item_id)
        elsif result.reason == :no_blessing
          @state.bless_wanted.clear
          Events.emit(:maintain_stuck, reason: 'No blessing on weapon')
        end
        result
      end

      def cast_sign(world, sign)
        item = sign.kind == :bless_411 ? world.hands.right : nil
        result = Actions::Cast.new(world, spell: sign.num, item: item).call
        Actions::WeaponBlessCheck.new(world, state: @state).call if %i[bless_902 bless_411].include?(sign.kind)
        result
      end

      # hunt_monitor 2359-2367: a blessed item that "strikes true" but is
      # shrugged off, when it is our ammo, in our inventory or in hand,
      # wants a bless; so does one whose blessing "returns to normal".
      def install_watch
        ammo = @policy.ammo.to_s
        state = @state
        Events.on(:bless_shrugged) do |e|
          next unless ammo == e.data[:noun] || e.data[:mine]

          state.bless_wanted << e.data[:id] unless state.bless_wanted.include?(e.data[:id])
        end
        Events.on(:bless_expired) { |e| state.bless_wanted << e.data[:id] unless state.bless_wanted.include?(e.data[:id]) }
      end
    end
  end
end
