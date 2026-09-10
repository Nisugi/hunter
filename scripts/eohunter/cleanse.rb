# frozen_string_literal: true

# ============================================================================
# cleanse (ecleanse 2.3.6 folded in: status removal, hazards, disarm
#          recovery, hive traps, the itchy curse)
# ============================================================================

#
# ecleanse is a main loop (1834) that reads the character's afflictions
# and the room's hazards every 0.2 s into an event stack, a DownstreamHook
# (1618) that queues the line-driven ones (disarms, the sanctum transform,
# the infected wound, weapon webbing, hive traps, the itchy curse, the
# entangling bind), and one Action per event that pauses every other
# script while it works (System.scripts_pause). The engine's Cleanse is
# that as the behavior at priority 5: wants_control? is the condition
# list, the Watch carries the line rules, and taking the tick IS the
# pause. Each ecleanse Action is an engine Action with the same gates and
# the same commands, bounded where ecleanse loops. Settings come from
# ecleanse.yaml (its setup window stays where it is). Rules and ecleanse
# line references in hunting-engine-plan.md, "Cleanse".
#
module EO::Engine
  module Cleanse
    KEYS = %i[
      cleanse_magical cleanse_grounded cleanse_poison cleanse_disease recover_disarmed
      dispel_clouds dispel_magic avoid_webs use_berserk_webbed hive_traps_apparatus hive_traps_ground
      break_runestone determination itchy_curse safe_room use_stunned_barkskin use_berserk_stunned
      use_stunned1040 use_stance1 use_stance2 use_flee use_hide use_709 use_619 use_213 use_1011
      use_9811 use_140 use_919 use_1635
      troubadours_rally
    ].freeze

    Policy = Struct.new(*KEYS, keyword_init: true) do
      def initialize(**opts)
        defaults = KEYS.to_h { |k| [k, k == :safe_room ? '' : false] }
        super(**defaults.merge(opts.slice(*KEYS)))
      end

      # ecleanse load_profile (670): data/<game>/<char>/ecleanse.yaml, else
      # the CharSettings defaults (637).
      def self.load(path, char_settings: {})
        require 'yaml'
        raw = File.exist?(path) ? (YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}) : {}
        raw = raw.to_h { |k, v| [k.to_sym, v] }
        defaults = %w[cleanse_magical cleanse_grounded cleanse_poison cleanse_disease recover_disarmed avoid_webs break_runestone determination]
                   .to_h { |k| [k.to_sym, char_settings[k] || false] }
        new(**defaults.merge(raw))
      end
    end

    # ecleanse Data (213): the spells this character has for each job, the
    # hazard patterns, the ids the game refused to target, the queued line
    # events, the disarm records.
    class State
      CAPPED = 200 # CappedCollection (189)

      attr_reader :queue, :bad_targets, :recover, :hive_trap_room, :creature
      attr_accessor :recover_seq, :rally_member_at

      def initialize
        @queue = []
        @bad_targets = []
        @recover = {}
        @recover_seq = 0
        @hive_trap_room = nil
        @creature = nil
        @rally_member_at = nil
      end

      def bad_target!(id)
        @bad_targets << id.to_s
        @bad_targets.shift while @bad_targets.size > CAPPED
      end

      def bad_target?(id) = @bad_targets.include?(id.to_s)

      def enqueue(event)
        @queue << event unless @queue.include?(event)
      end

      def hive_trap_room=(room)
        @hive_trap_room = room
      end

      def creature=(noun)
        @creature = noun
      end

      # record_disarm (1078): the ids in hand at the moment of the disarm,
      # so the recovered weapon is one that was not already there.
      def record_disarm(noun, hands, room_id, room_title)
        known = [hands.right, hands.left].map { |h| h&.id }.reject { |id| id.nil? || id.to_s.empty? }.map(&:to_s)
        key = @recover_seq
        @recover_seq += 1
        @recover[key] = { noun: noun, known_ids: known, room_id: room_id, title: room_title }
        key
      end
    end

    DEBUFFS = /Confusion|Vertigo|Sounds|Thought Lash|Mindwipe|Pious Trial|Powersink/
    DISPELLABLE = ['Confusion', 'Vertigo', 'Sounds', 'Thought Lash', 'Mindwipe', 'Pious Trial', 'Powersink'].freeze
    MAGIC_GLOBES = /silvery blue globe|spiraling ghostly rift|chaotic spatial anomaly/i
    RUNESTONES = /pale hovering runestone/i
    INVALID_CLOUDS = ['cloud of acidic mist', 'cloud of thick ethereal fog'].freeze
    INJURY_LOCATIONS = %w[leftHand rightHand leftArm rightArm leftEye rightEye nsys head].freeze
    TARGET_ANSWERS = Regexp.union(
      /^You can only target creatures, players, and creature-created hazards\.$/,
      /^Usage:  TARGET \{player\|creature\|hazard\}$/,
      /^You are now targeting .+\.$/,
      /^You are unable to discern the origin of .+\.$/,
      /^You discern that you are the origin of .+ and decide against targeting yourself\.$/,
      /^Suspecting that .+ is the origin of .+, you turn your attention towards \w+!$/
    )
    TARGET_OK = /^Suspecting that .+ is the origin of .+, you turn your attention towards \w+!$/

    # Which spell this character has for each job (Data 224-228).
    module Spells
      module_function

      def first_known(world, nums)
        nums.map { |n| world.spell[n] }.compact.find(&:known?)
      end

      def disease(world) = first_known(world, [113])
      def poison(world) = first_known(world, [114])
      def dispel(world) = first_known(world, [417, 1218, 119])
      def webs(world) = first_known(world, [209, 417, 1218, 119])
      def breeze(world) = first_known(world, [912, 612])
    end

    # Util.able_to_cast (1666): head, nervous system, eyes, arms and hands
    # wounds and scars against the casting limits, with Sigil of
    # Determination able to lift a rank-2 block when the policy allows.
    module Casting
      module_function

      def able?(world, policy)
        injuries = world.me.injuries
        return true if injuries.nil? || injuries.empty?

        able, try_sigil = check(injuries, limit: 1)
        return able if able || !try_sigil

        determination?(world, policy) ? check(injuries, limit: 2).first : false
      end

      # @return [Array(Boolean, Boolean)] able, and whether a sigil could help
      def check(injuries, limit:)
        left = { scar: 0, wound: 0 }
        right = { scar: 0, wound: 0 }
        injuries.each do |area, h|
          next unless area.to_s =~ /nsys|head|(left|right)(Eye|Arm|Hand)/

          scar = h['scar'].to_i
          wound = h['wound'].to_i
          next unless scar.positive? || wound.positive?
          return [false, false] if scar > 2 || wound > 2
          return [false, true] if limit == 1 && area.to_s =~ /nsys|head/ && (scar > 1 || wound > 1)

          side = area.to_s =~ /left/ ? left : (area.to_s =~ /right/ ? right : nil)
          next if side.nil?

          side[:scar] += scar
          side[:wound] += wound
          return [false, true] if side[:scar] > limit || side[:wound] > limit
        end
        [true, true]
      end

      def determination?(world, policy)
        return false unless policy.determination

        s = world.spell['Sigil of Determination']
        s && s.known? && s.affordable?
      end
    end

    module Predicates
      module_function

      def cloud(world, state)
        loot = Array(world.room.loot)
        found = loot.find { |l| l.name.to_s =~ /cloud/i && !INVALID_CLOUDS.include?(l.name.to_s) && l.type.to_s !~ /\bgem\b/i && !state.bad_target?(l.id) }
        found || (Spells.breeze(world) && loot.find { |l| l.name.to_s == 'cloud of acidic mist' && !state.bad_target?(l.id) })
      end

      def globe(world, state) = Array(world.room.loot).find { |l| l.name.to_s =~ MAGIC_GLOBES && !state.bad_target?(l.id) }
      def runestone(world, state) = Array(world.room.loot).find { |l| l.name.to_s =~ RUNESTONES && !state.bad_target?(l.id) }
      def web(world, state) = Array(world.room.loot).find { |l| l.noun.to_s =~ /web/i && !state.bad_target?(l.id) }

      def can_cleave?(world) = cman_known?('Spell Cleave') && world.me.stamina >= 10
      def can_thieve?(world) = cman_known?('Spell Thieve') && world.me.stamina >= 10

      def cman_known?(name)
        ::Lich::Gemstone::CMan.known?(name)
      rescue StandardError
        false
      end

      # ecleanse main_loop (1849-1882) in its order, gated the way each
      # Action gates itself so the behavior only claims a tick it can use.
      #
      # @return [Symbol, nil]
      def reason(world, policy, state)
        return :queued if state.queue.any?

        me = world.me
        # bigshot group_status_ailments (6716): with troubadours_rally and
        # 1040 known, a webbed, sleeping, stunned or frozen self gets
        # Troubadour's Rally before anything else, until clear (cmd_1040
        # 6281); a group member showing an ailment gets one cast (6720).
        if policy.troubadours_rally && world.spell[1040]&.known?
          return :rally if rally_needed?(me)
          return :rally_member if member_needs_rally?(world, state)
        end

        debuffs = me.debuff_names
        thorns = debuffs.any? { |k| k =~ /Wall of Thorns Poison/ }
        return :poison if policy.cleanse_poison && (me.poisoned? || thorns) && Spells.poison(world) && Casting.able?(world, policy)
        return :disease if policy.cleanse_disease && me.diseased? && Spells.disease(world) && Casting.able?(world, policy)
        return :stun if me.stunned? && stun_means?(world, policy)
        return :web_bound if (me.webbed? || me.bound?) && web_bound_means?(world, policy)
        return :grounded if policy.cleanse_grounded && debuffs.any? { |k| k =~ /Rooted|Pressed/ } && grounded_means?(world)
        return :magical if policy.cleanse_magical && debuffs.any? { |k| k =~ DEBUFFS } && Spells.dispel(world) && Casting.able?(world, policy)
        return :cloud if policy.dispel_magic && cloud(world, state) && hazard_means?(world, policy, cloud(world, state))
        return :globe if policy.dispel_magic && globe(world, state) && hazard_means?(world, policy, nil)
        return :runestone if policy.break_runestone && runestone(world, state)
        return :web if policy.avoid_webs && web(world, state) && (Spells.webs(world) && Casting.able?(world, policy) || can_cleave?(world) || can_thieve?(world))
        return :determination if policy.determination && injured_for_sigil?(world) && Casting.determination?(world, policy) && !me.effect_active?('Sigil of Determination')

        nil
      end

      def rally_needed?(me)
        me.webbed? || me.sleeping? || me.stunned? || me.frozen?
      end

      # A group member here with an ailment (6721), one cast each
      # RALLY_MEMBER_EVERY seconds (bigshot casts once per command).
      RALLY_MEMBER_EVERY = 10

      def member_needs_rally?(world, state, now = Time.now)
        return false if state.rally_member_at && now - state.rally_member_at < RALLY_MEMBER_EVERY

        nouns = world.group_nouns
        Array(world.room.players).any? { |p| p.status.to_s =~ EO::Engine::Survival::STUNNED && nouns.include?(p.noun.to_s) }
      end

      def injured_for_sigil?(world)
        injuries = world.me.injuries || {}
        INJURY_LOCATIONS.any? { |limb| injuries[limb].to_h['wound'].to_i > 1 }
      end

      def hazard_means?(world, policy, cloud)
        return Spells.breeze(world) && Casting.able?(world, policy) if cloud && cloud.name.to_s == 'cloud of acidic mist'

        (Spells.dispel(world) && Casting.able?(world, policy)) || can_cleave?(world) || can_thieve?(world)
      end

      # remove_stun (1390): every means the policy allows and the character has
      def stun_means?(world, policy)
        me = world.me
        escape_room = Actions::Escape.kind_for(world.room.title)
        return true if policy.use_stunned1040 && world.spell[1040]&.known?
        return true if policy.use_stunned_barkskin && world.spell[605]&.known? && !me.cooldown_active?('Barkskin: Commune') && !me.cooldown_active?('Barkskin') && !me.spell_active?(605) && me.blessings_ranks >= 15
        return true if policy.use_1635 && world.spell[1635]&.known?
        return false if escape_room

        (policy.use_berserk_stunned && cman_available?('Berserk')) ||
          (policy.use_stance1 && cman_available?('Stun Maneuvers', min_rank: 3)) ||
          (policy.use_stance2 && cman_available?('Stun Maneuvers', min_rank: 4)) ||
          (policy.use_flee && cman_available?('Stun Maneuvers', min_rank: 5)) ||
          (policy.use_hide && cman_available?('Stun Maneuvers', min_rank: 5) && !me.hidden?)
      end

      def web_bound_means?(world, policy)
        return false unless policy.avoid_webs || policy.use_berserk_webbed

        me = world.me
        (world.spell[1040]&.known? && world.spell[1040].affordable?) ||
          (policy.use_berserk_webbed && cman_known?('Berserk') && me.stamina >= 21) ||
          (policy.use_1635 && world.spell[1635]&.known? && world.spell[1635].affordable?) ||
          (feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15)
      end

      def grounded_means?(world)
        me = world.me
        return me.stamina >= 11 if cman_known?('Retreat')

        me.debuff_active?('Rooted') && feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15
      end

      def cman_available?(name, min_rank: 1)
        ::Lich::Gemstone::CMan.available?(name, min_rank: min_rank)
      rescue StandardError
        false
      end

      def feat_available?(name, min_rank: 1)
        ::Lich::Gemstone::Feat.available?(name, min_rank: min_rank)
      rescue StandardError
        false
      end
    end
  end

  module Actions
    # Shared pieces of the ecleanse actions: MANA PULSE before a spell we
    # cannot afford (1027), TARGET a hazard (697), a command read through
    # roundtime (Util.get_res 1777).
    module CleanseHelpers
      MANA_PULSE = /An invigorating rush of mana pulses through you|You are too mentally fatigued to attempt this ability|You're already at full mana\.|Your mana control skills are not yet advanced/i

      def mana_pulse(spell)
        return if spell.nil? || !spell.known? || spell.affordable?

        send_and_match('mana pulse', MANA_PULSE, timeout: 2)
        sleep 0.2
      end

      # TARGET #id; false marks the id bad (the game refused) for the caller.
      def target_hazard(obj)
        result = send_and_match("target ##{obj.id}", Cleanse::TARGET_ANSWERS, timeout: 2)
        result.success? && result.line =~ Cleanse::TARGET_OK ? true : false
      end

      def cleave_or_thieve(obj)
        if Cleanse::Predicates.can_cleave?(@world)
          send_and_match("cman scleave ##{obj.id}", /.*/, timeout: 3)
        elsif Cleanse::Predicates.can_thieve?(@world)
          send_and_match("cman sthieve ##{obj.id}", /.*/, timeout: 3)
        end
      end

      def wait_rt
        sleep 0.2
        settle_rt
        sleep 0.2
      end

      def stand_up
        3.times do
          break if me.standing?

          send_through_ladder('stand')
          sleep 0.3
        end
      end
    end

    # remove_poison (1361), remove_disease (1298): cast until clear or
    # unaffordable.
    class CleanseAffliction < Base
      include CleanseHelpers

      MAX_CASTS = 6

      def initialize(world, kind:, **opts)
        super(world, **opts)
        @kind = kind
      end

      def preconditions
        return :dead if me.dead?

        @spell = @kind == :poison ? Cleanse::Spells.poison(@world) : Cleanse::Spells.disease(@world)
        return :no_spell if @spell.nil?

        :ok
      end

      def perform
        mana_pulse(@spell)
        return Result.new(status: :failed, reason: :unaffordable) unless @spell.affordable?

        MAX_CASTS.times do
          break unless afflicted? && @spell.affordable?
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          @spell.cast
          wait_rt
        end
        afflicted? ? Result.new(status: :failed, reason: :still_afflicted) : Result.new(status: :success, reason: @kind)
      end

      private

      def afflicted?
        return me.diseased? if @kind == :disease

        me.poisoned? || me.debuff_names.any? { |k| k =~ /Wall of Thorns Poison/ }
      end
    end

    # remove_magical (1337): stand, then channel the dispel open at
    # ourselves once per active dispellable debuff.
    class CleanseMagical < Base
      include CleanseHelpers

      def preconditions
        return :dead if me.dead?

        @spell = Cleanse::Spells.dispel(@world)
        @spell ? :ok : :no_spell
      end

      def perform
        mana_pulse(@spell)
        cast = 0
        Cleanse::DISPELLABLE.each do |debuff|
          next unless me.debuff_active?(debuff)

          mana_pulse(@spell)
          stand_up
          wait_rt
          break unless @spell.affordable?

          @spell.force_incant('channel open')
          cast += 1
        end
        Result.new(status: cast.positive? ? :success : :failed, reason: cast.positive? ? :dispelled : :unaffordable)
      end
    end

    # remove_grounded (1314): CMAN RETREAT with the target cleared and
    # restored, else Escape Artist for a root.
    class CleanseGrounded < Base
      include CleanseHelpers

      def preconditions = me.dead? ? :dead : :ok

      def perform
        if Cleanse::Predicates.cman_known?('Retreat')
          done = false
          %w[Rooted Pressed].each do |debuff|
            next unless me.debuff_active?(debuff) && me.stamina >= 11

            wait_rt
            stand_up
            wait_rt
            current = me.current_target_id
            send_through_ladder('target clear')
            send_through_ladder('cman retreat')
            send_through_ladder("target ##{current}") if current
            done = true
          end
          Result.new(status: done ? :success : :failed, reason: done ? :retreat : :no_means)
        elsif me.debuff_active?('Rooted') && Cleanse::Predicates.feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15
          Maneuver.new(@world, category: :feat, name: 'escapeartist', interrupt: @interrupt).call
        else
          Result.new(status: :failed, reason: :no_means)
        end
      end
    end

    # remove_stun (1390): the first means the policy allows, in ecleanse's
    # order: barkskin, berserk, 1040, beseech, then the Stun Maneuvers
    # stances, flee and hide.
    class CleanseStun < Base
      include CleanseHelpers

      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        p = @policy
        spell = @world.spell
        escape_room = Escape.kind_for(@world.room.title)
        if p.use_stunned_barkskin && spell[605]&.known? && !me.cooldown_active?('Barkskin: Commune') && !me.cooldown_active?('Barkskin') && !me.spell_active?(605) && me.blessings_ranks >= 15
          mana_pulse(spell[605])
          if spell[605].available?
            wait_rt
            send_through_ladder('commune barkskin') if me.stunned?
            return wait_unstunned(:barkskin)
          end
        end
        if !escape_room && p.use_berserk_stunned && Cleanse::Predicates.cman_available?('Berserk')
          spell[9607].cast
          sleep 1
          return wait_while_active(9607, :berserk)
        end
        if p.use_stunned1040 && spell[1040]&.known?
          mana_pulse(spell[1040])
          if spell[1040].available?
            send_through_ladder('shout 1040')
            return Result.new(status: :success, reason: :shout_1040)
          end
        end
        if p.use_1635 && spell[1635]&.known?
          mana_pulse(spell[1635])
          if spell[1635].available?
            send_through_ladder('beseech')
            return Result.new(status: :success, reason: :beseech)
          end
        end
        return Result.new(status: :failed, reason: :no_means) if escape_room

        return stunman('stance1') if p.use_stance1 && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 3)
        return stunman('stance2') if p.use_stance2 && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 4)
        return stunman('flee') if p.use_flee && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 5)
        return stunman('hide') if p.use_hide && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 5) && !me.hidden?

        Result.new(status: :failed, reason: :no_means)
      end

      private

      # stunman_perform (1516) through CMan.use, as ecleanse does since 2.2.8
      def stunman(type)
        stunman_stand
        case type
        when 'stance1', 'stance2' then stunman_use(type)
        when 'flee'
          room = @world.room.id
          8.times do
            break if @world.room.id != room || !me.stunned? || interrupted?

            stunman_stand
            stunman_use('flee')
            sleep 0.5
          end
          stunman_use('stance2')
        when 'hide'
          8.times do
            break if me.hidden? || !me.stunned? || interrupted?

            stunman_stand
            stunman_use('hide')
            wait_rt
          end
        end
        wait_unstunned(:"stunman_#{type}")
      end

      def stunman_stand
        4.times do
          break if me.standing? || !me.stunned?

          stunman_use('stand')
          wait_rt
        end
      end

      def stunman_use(arg) = ::Lich::Gemstone::CMan.use('stunman', arg)

      def wait_unstunned(reason)
        deadline = clock_now + 60
        sleep 0.25 while me.stunned? && clock_now < deadline && !interrupted? && !me.dead?
        Result.new(status: :success, reason: reason)
      end

      def wait_while_active(num, reason)
        deadline = clock_now + 60
        sleep 0.5 while me.spell_active?(num) && clock_now < deadline && !interrupted?
        Result.new(status: :success, reason: reason)
      end
    end

    # remove_web_bound (1444): 1040, else berserk, else beseech, else
    # Escape Artist.
    class CleanseWebBound < Base
      include CleanseHelpers

      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        spell = @world.spell
        mana_pulse(spell[1040]) if spell[1040]&.known?
        if spell[1040]&.known? && spell[1040].affordable?
          send_through_ladder('shout 1040')
          Result.new(status: :success, reason: :shout_1040)
        elsif @policy.use_berserk_webbed && Cleanse::Predicates.cman_known?('Berserk') && me.stamina >= 21
          spell[9607].cast
          sleep 1
          deadline = clock_now + 60
          sleep 0.5 while me.spell_active?(9607) && clock_now < deadline && !interrupted?
          Result.new(status: :success, reason: :berserk)
        elsif @policy.use_1635 && spell[1635]&.known? && spell[1635].affordable?
          send_through_ladder('beseech')
          Result.new(status: :success, reason: :beseech)
        elsif Cleanse::Predicates.feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15
          Maneuver.new(@world, category: :feat, name: 'escapeartist', interrupt: @interrupt).call
        else
          Result.new(status: :failed, reason: :no_means)
        end
      end
    end

    # dispel_cloud (819), avoid_globe (716), avoid_webs (686): TARGET the
    # hazard (a refusal marks it bad), then the dispel, else Spell Cleave
    # or Thieve. The acidic mist takes the breeze spell instead.
    class CleanseHazard < Base
      include CleanseHelpers

      def initialize(world, kind:, object:, state:, policy:, **opts)
        super(world, **opts)
        @kind = kind
        @object = object
        @state = state
        @policy = policy
      end

      def preconditions
        return :dead if me.dead?
        return :gone unless Array(@world.room.loot).any? { |l| l.id.to_s == @object.id.to_s }

        :ok
      end

      def perform
        acid = @kind == :cloud && @object.name.to_s == 'cloud of acidic mist'
        spell = @kind == :web ? Cleanse::Spells.webs(@world) : Cleanse::Spells.dispel(@world)
        able = Cleanse::Casting.able?(@world, @policy)
        unless acid || (@object.name.to_s =~ /silvery blue globe|spiraling ghostly rift/)
          unless target_hazard(@object)
            @state.bad_target!(@object.id)
            return Result.new(status: :failed, reason: :untargetable)
          end
        end

        if acid
          breeze = Cleanse::Spells.breeze(@world)
          return Result.new(status: :failed, reason: :no_means) unless breeze && able && breeze.affordable?

          breeze.num == 912 ? breeze.force_incant : breeze.cast("at ##{@object.id}")
          Result.new(status: :success, reason: :breeze)
        elsif spell && able
          mana_pulse(spell)
          return Result.new(status: :failed, reason: :unaffordable) unless spell.affordable?

          spell.cast("at ##{@object.id}")
          Result.new(status: :success, reason: :dispelled)
        else
          cleave_or_thieve(@object)
          Result.new(status: :success, reason: :cleaved)
        end
      end
    end

    # avoid_runestone (748): TARGET it, then ATTACK until it shatters, five
    # swings at most.
    class CleanseRunestone < Base
      include CleanseHelpers
      include CombatRt

      def initialize(world, object:, state:, **opts)
        super(world, **opts)
        @object = object
        @state = state
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        unless target_hazard(@object)
          @state.bad_target!(@object.id)
          return Result.new(status: :failed, reason: :untargetable)
        end

        5.times do
          settle_rt
          result = send_and_match("attack ##{@object.id}", /It crashes to the ground and shatters into pale dust|^Roundtime|What were you referring to/, timeout: 3)
          return Result.new(status: :success, reason: :shattered) if result.success? && result.line =~ /shatters/
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          break unless Array(@world.room.loot).any? { |l| l.id.to_s == @object.id.to_s }
        end
        Result.new(status: :success, reason: :runestone_done)
      end
    end

    # bigshot cmd_1040 (6271) on ourselves: MANA PULSE when 1040 is known
    # but unaffordable, then one cast; the engine ticks again while the
    # ailment holds, which is bigshot's until-clear loop.
    class CleanseRally < Base
      include CleanseHelpers

      def preconditions
        return :dead if me.dead?
        return :unknown_spell unless @world.spell[1040]&.known?

        :ok
      end

      def perform
        s = @world.spell[1040]
        wait_rt
        mana_pulse(s)
        return Result.new(status: :failed, reason: :unaffordable) unless s.affordable?

        s.cast
        Result.new(status: :success, reason: :rally_1040)
      end
    end

    # determination (810)
    class CleanseDetermination < Base
      def preconditions = me.dead? ? :dead : :ok

      def perform
        s = @world.spell['Sigil of Determination']
        return Result.new(status: :failed, reason: :unaffordable) unless s && s.affordable?

        s.cast
        Result.new(status: :success, reason: :determination)
      end
    end

    # settle_room (1495): one defensive spell before a recovery, by policy.
    class CleanseSettleRoom < Base
      include CleanseHelpers

      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      def preconditions
        return :dead if me.dead?
        return :quiet if Array(@world.room.targets).empty?

        :ok
      end

      def perform
        p = @policy
        spell = @world.spell
        return Result.new(status: :failed, reason: :cannot_cast) unless Cleanse::Casting.able?(@world, p)

        if p.use_140 && spell[140]&.known? && !me.effect_active?('Wall of Force') && !me.cooldown_active?('Wall of Force')
          cast(spell[140])
        elsif p.use_619 && spell[619]&.known?
          cast(spell[619])
        elsif p.use_709 && spell[709]&.known? && Array(@world.room.creatures).none? { |c| c.noun.to_s =~ Targets::APPENDAGE_NOUNS }
          cast(spell[709])
        elsif p.use_919 && !me.effect_active?("Wizard's Shield") && !me.cooldown_active?("Wizard's Shield")
          cast(spell[919])
        elsif p.use_9811 && spell[9811]&.known?
          spell[9811].cast
          Result.new(status: :success, reason: :settled)
        else
          Result.new(status: :failed, reason: :no_means)
        end
      end

      private

      def cast(s)
        mana_pulse(s)
        return Result.new(status: :failed, reason: :unaffordable) unless s&.affordable?

        s.cast
        Result.new(status: :success, reason: :settled)
      end
    end

    # recover (1088): back to the disarm room, 213/1011 by policy, the
    # servant when 218 is up, settle the room, defensive, a bonded weapon's
    # own return, else empty hands, kneel, RECOVER ITEM up to ten times,
    # stand, fill hands.
    class CleanseRecover < Base
      include CleanseHelpers

      SEARCHES = 10
      RECOVER_ANSWERS = /<dialogData|You spy|You continue to intently search the area|In order to recover something|You find nothing recoverable|You're not in any condition to be searching around/

      # The trip back to the disarm room is the behavior's (a Travel trip
      # before this action runs); here we are in place.
      def initialize(world, record:, policy:, **opts)
        super(world, **opts)
        @record = record
        @policy = policy
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        known = @record[:known_ids]
        noun = @record[:noun]
        room_id = @record[:room_id]
        Events.emit(:disarmed, noun: noun, room: room_id, title: @record[:title])
        wait_rt
        stops = cast_213_1011
        if me.spell_active?(218) && servant_recover?
          stops.each { |n| send_through_ladder("stop #{n}") }
          return Result.new(status: :success, reason: :servant)
        end

        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        stance_defensive
        recovered = false
        if bonded?
          deadline = clock_now + 10
          wait_rt until recovered?(known, noun) || clock_now > deadline || interrupted?
          recovered = recovered?(known, noun)
        end
        unless recovered
          send_through_ladder('stow all')
          SEARCHES.times do
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            @travel.call(room_id) if room_id && @world.room.id != room_id
            kneel
            wait_rt
            lines = command_lines('recover item', RECOVER_ANSWERS)
            if lines.any? { |l| l =~ /You spy (?:an|a) (?:.*) and recover it!/ } || recovered?(known, noun)
              recovered = true
              break
            end
            if lines.any? { |l| l =~ /You're not in any condition to be searching around/ }
              stand_up
              stops.each { |n| send_through_ladder("stop #{n}") }
              Events.emit(:cleanse_stuck, reason: "Unable to search; #{noun} is in room #{room_id}")
              return Result.new(status: :failed, reason: :cannot_search)
            end
            send_through_ladder('stow all') if lines.any? { |l| l =~ /In order to recover something/ }
          end
          wait_rt
        end
        stand_up
        wait_rt
        fill_hands
        stops.each { |n| send_through_ladder("stop #{n}") }
        Result.new(status: recovered ? :success : :failed, reason: recovered ? :recovered : :not_recovered)
      end

      private

      def cast_213_1011
        stops = []
        return stops unless Cleanse::Casting.able?(@world, @policy)

        [[213, @policy.use_213], [1011, @policy.use_1011]].each do |num, on|
          s = @world.spell[num]
          next unless on && s&.known?

          mana_pulse(s)
          s.cast if s.affordable?
          stops << num
        end
        wait_rt
        stops
      end

      def servant_recover?
        15.times do
          break if Array(@world.room.creatures).any? { |c| c.noun.to_s =~ /spirit/i }

          sleep 0.1
        end
        result = send_and_match('tell servant recover', /flickers for a moment and manifests|has no personal recollection/, timeout: 5)
        result.success? && result.line =~ /flickers for a moment and manifests/
      end

      # recovered? (1057): a hand holds an item that was not there at the
      # disarm, with the disarmed noun when known.
      def recovered?(known_ids, noun)
        [@world.hands.right, @world.hands.left].any? do |h|
          next false if h.nil? || h.id.nil? || h.name.to_s == 'Empty' || known_ids.include?(h.id.to_s)

          noun.nil? || h.noun.to_s.casecmp?(noun.to_s)
        end
      end

      def bonded?
        (::Lich::Gemstone::Feat.weapon_bonding == 5) || @world.spell[1625]&.known?
      rescue StandardError
        @world.spell[1625]&.known? || false
      end

      def kneel
        3.times do
          break if me.kneeling?

          send_and_match('kneel', /You kneel|You are already/i, timeout: 2)
        end
      end

      def stance_defensive
        ::Lich::Gemstone::Stance.change('defensive')
      rescue StandardError
        send_through_ladder('stance defensive')
      end

      def fill_hands
        ::Lich::Stash.equip_hands(both: true)
      rescue StandardError
        nil
      end

      # Util.get_command (1749): the command's lines, re-sent through roundtime
      def command_lines(command, regex)
        ::Lich::Util.issue_command(command, Regexp.union(regex, /(?:\.\.\.wait) (\d+) [Ss]ec(?:onds)?\./), timeout: 5)
      rescue StandardError
        []
      end
    end

    # recover_weapon_webbing (1240): PRY the weapon free, ten tries.
    class CleansePry < Base
      include CleanseHelpers

      def initialize(world, record:, policy:, **opts)
        super(world, **opts)
        @record = record
        @policy = policy
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        10.times do
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          result = send_and_match("pry my #{@record[:noun]}", /^Pry what|^You try to pry your|^You pry your.*free from the webbing/, timeout: 3)
          return Result.new(status: :success, reason: :pried) if result.success? && result.line =~ /You pry your|Pry what/i
        end
        Result.new(status: :failed, reason: :still_webbed)
      end
    end

    # telekinetic_recover (1548): the dispel at the floating weapon, else
    # GET it, until a hand holds it.
    class CleanseTelekinetic < Base
      include CleanseHelpers

      def initialize(world, record:, policy:, **opts)
        super(world, **opts)
        @record = record
        @policy = policy
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        noun = @record[:noun]
        known = @record[:known_ids]
        spell = Cleanse::Spells.dispel(@world)
        6.times do
          return Result.new(status: :success, reason: :recovered) if [@world.hands.right, @world.hands.left].any? { |h| h&.id && !known.include?(h.id.to_s) && h.noun.to_s.casecmp?(noun.to_s) }
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          if spell
            mana_pulse(spell)
            spell.cast("at #{noun}") if spell.affordable?
          else
            send_through_ladder("get #{noun}")
          end
          wait_rt
        end
        Result.new(status: :failed, reason: :not_recovered)
      end
    end

    # sanctum_recover (1470): CLENCH the transformed weapon back.
    class CleanseSanctum < Base
      include CleanseHelpers

      def initialize(world, creature:, policy:, **opts)
        super(world, **opts)
        @creature = creature
        @policy = policy
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        wait_rt
        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        6.times do
          result = send_and_match("clench #{@creature}", /You reach up and grab|I could not find what you were referring to\./, timeout: 3)
          wait_rt
          return Result.new(status: :success, reason: :clenched) if result.success?
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
        end
        Result.new(status: :failed, reason: :not_clenched)
      end
    end

    # hive_traps_apparatus (947), hive_traps_ground (980): SEARCH until the
    # trap resolves, then DISARM APPARATUS; three of each, twenty seconds.
    class CleanseHiveTrap < Base
      include CleanseHelpers

      ATTEMPTS = 3
      DEADLINE = 20
      SEARCH = /d100: |You don't find anything of interest here|You can't see well enough to search around/
      DISARM = /d100: |You want to disarm what\?|You can't see well enough/

      def initialize(world, kind:, state:, **opts)
        super(world, **opts)
        @kind = kind
        @state = state
      end

      def preconditions
        return :dead if me.dead?
        return :moved unless @state.hive_trap_room && @world.room.id == @state.hive_trap_room

        :ok
      end

      def perform
        result = search
        if result == :found && @kind == :apparatus
          deadline = clock_now + DEADLINE
          ATTEMPTS.times do
            break if @world.room.id != @state.hive_trap_room || me.dead? || me.muckled? || clock_now > deadline || interrupted?

            wait_rt
            lines = command_lines('disarm apparatus', DISARM)
            break if lines.any? { |l| l =~ /Success!|You want to disarm what\?/ }
          end
        end
        @state.hive_trap_room = nil unless %i[moved muckled].include?(result)
        wait_rt
        Result.new(status: :success, reason: result)
      end

      private

      def search
        deadline = clock_now + DEADLINE
        ATTEMPTS.times do
          return :moved if @world.room.id != @state.hive_trap_room
          return :muckled if me.dead? || me.muckled?
          return :timeout if clock_now > deadline
          return :interrupted if interrupted?

          wait_rt
          lines = command_lines('search', SEARCH)
          return :blind if lines.any? { |l| l =~ /You can't see well enough to search around/ }
          return :clear if lines.any? { |l| l =~ /You don't find anything of interest here/ }
          return :found if lines.any? { |l| l =~ /Success!/ }
        end
        :exhausted
      end

      def command_lines(command, regex)
        ::Lich::Util.issue_command(command, Regexp.union(regex, /(?:\.\.\.wait) (\d+) [Ss]ec(?:onds)?\./), timeout: 5)
      rescue StandardError
        []
      end
    end

    # itchy_curse (993): in the safe room (the profile's, else the nearest
    # town or sanctuary), empty hands, wait out the rash. The trips there
    # and back are the behavior's, around this action.
    class CleanseItchyCurse < Base
      include CleanseHelpers

      RASH_GONE = /You no longer feel so defenseless and the rash seems to disappear\./

      # Where to wait it out: a room id, a map tag, or nil for none.
      def self.safe_room(world, policy)
        return policy.safe_room.to_i if policy.safe_room.to_s =~ /\A\d+\z/
        return policy.safe_room unless policy.safe_room.to_s.empty?

        world.nearest_safe_room
      rescue StandardError
        nil
      end

      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        send_through_ladder('stow all')
        deadline = clock_now + 180
        cleared = false
        until clock_now > deadline || interrupted?
          line = next_line
          if line.nil?
            sleep 1
            next
          end
          if line =~ RASH_GONE
            cleared = true
            break
          end
        end
        ::Lich::Stash.equip_hands(both: true) rescue nil
        Result.new(status: cleared ? :success : :failed, reason: cleared ? :rash_gone : :rash_timeout)
      end
    end

    # use_vat (1587): CLEAN VAT at the Sanctum's vat for the infected
    # wound. The trips there and back are the behavior's.
    class CleanseVat < Base
      include CleanseHelpers

      VAT_UID = 4216054

      def self.vat_room(world)
        world.uid_ids(VAT_UID).first
      rescue StandardError
        nil
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        send_and_match('clean vat', /.*/, timeout: 3)
        wait_rt
        Result.new(status: :success, reason: :vat)
      end
    end
  end

  module Behaviors
    # Priority 5: after Survival, before Flee.
    #
    # Three queued jobs travel: the disarm recovery (back to the disarm
    # room), the itchy curse (to a safe room and back) and the vat (to the
    # Sanctum and back). Each is a Job of stages, one Travel trip tick or
    # one action per engine tick, so the trip is supervised, suspended
    # when Survival takes control, and never blocks the loop.
    class Cleanse < Behavior
      attr_reader :state, :reason, :job

      # A travelling job: go (to +dest+, skipped when nil or already
      # there), act (+action+ built there), return (to +home+, when set
      # and not there). The act's Result is the job's; a trip that fails
      # ends the job with :could_not_reach.
      Job = Struct.new(:name, :dest, :home, :action, :stage, :result, keyword_init: true)

      # @param travel [#call] (room) -> Trip or Boolean; default a Travel trip
      def initialize(policy:, state: EO::Engine::Cleanse::State.new, travel: nil)
        super()
        @policy = policy
        @state = state
        @travel = travel || EO::Engine::Travel.default
        @trip = nil
        @job = nil
        install
      end

      def priority = 5

      # The engine's stop: end a trip in flight, drop the job.
      def cancel!
        EO::Engine::Travel.cancel(self)
        @job = nil
      end

      # Another behavior took control: hold the trip; the job resumes.
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      def wants_control?(world)
        return true if @job

        @reason = EO::Engine::Cleanse::Predicates.reason(world, @policy, @state)
        !@reason.nil?
      end

      def tick(world)
        return step_job(world) if @job

        reason = @reason || EO::Engine::Cleanse::Predicates.reason(world, @policy, @state)
        return nil if reason.nil?

        Events.emit(:cleansing, reason: reason)
        result = reason == :queued ? run_queued(world, @state.queue.shift) : run_condition(world, reason)
        Events.emit(:cleansed, reason: reason, result: result&.reason) if result && @job.nil?
        result
      end

      private

      def start_job(world, name:, dest:, home:, &action)
        @job = Job.new(name: name, dest: dest, home: home, action: action, stage: :go)
        step_job(world)
      end

      def step_job(world)
        job = @job
        case job.stage
        when :go
          if job.dest && world.room.id != job.dest
            outcome = EO::Engine::Travel.step(self, @travel, job.dest, world)
            return nil if outcome == :underway
            return end_job(Actions::Result.new(status: :failed, reason: :could_not_reach)) if outcome == :failed
          end
          job.stage = :act
          step_job(world)
        when :act
          job.result = job.action.call(world)
          Events.emit(:cleansed, reason: job.name, result: job.result&.reason)
          job.stage = :return
          return end_job(job.result) if job.home.nil? || world.room.id == job.home

          nil
        when :return
          outcome = EO::Engine::Travel.step(self, @travel, job.home, world)
          return nil if outcome == :underway

          Events.emit(:cleanse_stuck, reason: "Could not return to #{job.home} after #{job.name}") if outcome == :failed
          end_job(job.result)
        end
      end

      def end_job(result)
        @job = nil
        result
      end

      def run_condition(world, reason)
        p = @policy
        case reason
        when :poison then Actions::CleanseAffliction.new(world, kind: :poison).call
        when :disease then Actions::CleanseAffliction.new(world, kind: :disease).call
        when :stun then Actions::CleanseStun.new(world, policy: p).call
        when :web_bound then Actions::CleanseWebBound.new(world, policy: p).call
        when :grounded then Actions::CleanseGrounded.new(world).call
        when :magical then Actions::CleanseMagical.new(world).call
        when :cloud then Actions::CleanseHazard.new(world, kind: :cloud, object: EO::Engine::Cleanse::Predicates.cloud(world, @state), state: @state, policy: p).call
        when :globe then Actions::CleanseHazard.new(world, kind: :globe, object: EO::Engine::Cleanse::Predicates.globe(world, @state), state: @state, policy: p).call
        when :web then Actions::CleanseHazard.new(world, kind: :web, object: EO::Engine::Cleanse::Predicates.web(world, @state), state: @state, policy: p).call
        when :runestone then Actions::CleanseRunestone.new(world, object: EO::Engine::Cleanse::Predicates.runestone(world, @state), state: @state).call
        when :determination then Actions::CleanseDetermination.new(world).call
        when :rally then Actions::CleanseRally.new(world).call
        when :rally_member
          @state.rally_member_at = Time.now
          Actions::CleanseRally.new(world).call
        end
      end

      # The line-driven events (set_hooks 1618), each a queued job.
      def run_queued(world, event)
        p = @policy
        case event[:event]
        when :recover
          record = @state.recover.delete(event[:key])
          return nil unless record

          start_job(world, name: :recover, dest: record[:room_id], home: nil) { |w| Actions::CleanseRecover.new(w, record: record, policy: p).call }
        when :telekinetic_recover
          record = @state.recover.delete(event[:key])
          record ? Actions::CleanseTelekinetic.new(world, record: record, policy: p).call : nil
        when :recover_weapon_webbing
          record = @state.recover.delete(event[:key])
          record ? Actions::CleansePry.new(world, record: record, policy: p).call : nil
        when :sanctum_recover then p.recover_disarmed ? Actions::CleanseSanctum.new(world, creature: @state.creature, policy: p).call : nil
        when :use_vat
          vat = Actions::CleanseVat.vat_room(world)
          return Actions::Result.new(status: :failed, reason: :no_vat_room) if vat.nil?

          start_job(world, name: :use_vat, dest: vat, home: world.room.id) { |w| Actions::CleanseVat.new(w).call }
        when :hive_traps_apparatus then p.hive_traps_apparatus ? Actions::CleanseHiveTrap.new(world, kind: :apparatus, state: @state).call : nil
        when :hive_traps_ground then p.hive_traps_ground ? Actions::CleanseHiveTrap.new(world, kind: :ground, state: @state).call : nil
        when :itchy_curse
          return nil unless p.itchy_curse

          safe = Actions::CleanseItchyCurse.safe_room(world, p)
          return Actions::Result.new(status: :failed, reason: :no_safe_room) if safe.nil?

          start_job(world, name: :itchy_curse, dest: safe, home: world.room.id) { |w| Actions::CleanseItchyCurse.new(w, policy: p).call }
        when :remove_web_bound then Actions::CleanseWebBound.new(world, policy: p).call
        end
      end

      def install
        state = @state
        policy = @policy
        Events.on(:disarm_seen) do |e|
          next unless policy.recover_disarmed

          key = state.record_disarm(e.data[:noun], e.data[:hands], e.data[:room_id], e.data[:title])
          state.enqueue(event: e.data[:kind], key: key)
        end
        Events.on(:sanctum_transform) { |e| state.creature = e.data[:noun]; state.enqueue(event: :sanctum_recover) }
        Events.on(:infected_wound) { state.enqueue(event: :use_vat) }
        Events.on(:hive_trap) { |e| state.hive_trap_room = e.data[:room_id]; state.enqueue(event: e.data[:kind]) }
        Events.on(:itchy_curse) { state.enqueue(event: :itchy_curse) }
        Events.on(:entangled) { state.enqueue(event: :remove_web_bound) }
      end
    end
  end
end

# ecleanse set_hooks (1618): the line-driven events. The disarm lines carry
# the weapon noun; the record needs the hands and room at that moment, so
# the data block reads them here.
module EO::Engine
  module Cleanse
    def self.disarm_data(kind, noun)
      world = World.new
      { kind: kind, noun: noun, hands: world.hands, room_id: world.room.id, title: world.room.title }
    rescue StandardError
      { kind: kind, noun: noun, hands: nil, room_id: nil, title: nil }
    end
  end
end

EO::Engine::Watch.on(%r{Your <a exist="[^"]+" noun="(?<noun>[^"]+)">[^<]+</a> is knocked from your grasp}, :disarm_seen) { |m| EO::Engine::Cleanse.disarm_data(:recover, m[:noun]) }
EO::Engine::Watch.on(%r{your <a exist="[^"]+" noun="(?<noun>[^"]+)">[^<]+</a> at .+?\.  The weapon rebounds off of the hardened .+? and is wrenched from your hand\.  It slides along the ground and disappears into the shadows!}, :disarm_seen) { |m| EO::Engine::Cleanse.disarm_data(:recover, m[:noun]) }
EO::Engine::Watch.on(%r{^Your <a exist="[^"]+" noun="(?<noun>[^"]+)">[^<]+</a> strikes one of the bony protrusions on <pushBold/>an? <a exist="\d+" noun="[^"]+">[^<]+</a><popBold/> \w+ and it is wrenched out of your grasp!}, :disarm_seen) { |m| EO::Engine::Cleanse.disarm_data(:recover, m[:noun]) }
EO::Engine::Watch.on(%r{^You swing your <a exist="[^"]+" noun="(?<noun>[^"]+)">[^<]+</a> at <pushBold/>(?:an?|the) <a exist="[^"]+" noun="[^"]+">[^<]+</a><popBold/>\.  The weapon strikes one of the bony protrusions on the <pushBold/><a exist="[^"]+" noun="[^"]+">[^<]+</a><popBold/> \w+ and it is wrenched out of your grasp!}, :disarm_seen) { |m| EO::Engine::Cleanse.disarm_data(:recover, m[:noun]) }
EO::Engine::Watch.on(%r{Your <a exist="[^"]+" noun="(?<noun>[^"]+)">[^<]+</a> tears free from your hands and floats}, :disarm_seen) { |m| EO::Engine::Cleanse.disarm_data(:telekinetic_recover, m[:noun]) }
EO::Engine::Watch.on(%r{The webbing entangles your <a exist=".*?" noun="(?<noun>.*?)">.*?</a>, rendering it useless}, :disarm_seen) { |m| EO::Engine::Cleanse.disarm_data(:recover_weapon_webbing, m[:noun]) }
EO::Engine::Watch.on(%r{Striking with a serpent's unsettling quickness, (?:.*)\.  Vile (?:.*), kindling it into an unholy semblance of life.  The (?:.*) form twists and mutates, sprouting scales and cold eyes as it transforms into a <a exist="\d+" noun="(?<noun>[^"]+)">[^<]+</a>!}, :sanctum_transform) { |m| { noun: m[:noun] } }
EO::Engine::Watch.on(/The flesh around the wound feels hot and cold at the same time, heavy with infection\./, :infected_wound)
EO::Engine::Watch.on(/You notice a flickering glint in the shadows|The apparatus flickers with deadly radiance/, :hive_trap) { |_m| { kind: :hive_traps_apparatus, room_id: (EO::Engine::World.new.room.id rescue nil) } }
EO::Engine::Watch.on(/The ground churns violently as flashes of chitin jut from its depths|The ground underfoot churns violently and huge chitinous mandibles flash as the insectoid monstrosity below goes into a feeding frenzy!|Hindered by the churning terrain, you are helpless as the concealed assailant's mandibles snap at you from the safety of its pit trap!/, :hive_trap) { |_m| { kind: :hive_traps_ground, room_id: (EO::Engine::World.new.room.id rescue nil) } }
EO::Engine::Watch.on(/You shiver slightly as an invisible rash covers your body/, :itchy_curse)
EO::Engine::Watch.on(/^An unseen force entangles you, restricting your movement!/, :entangled)
