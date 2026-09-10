# frozen_string_literal: true

# ============================================================================
# routines (the rest of bigshot's cmd_* vocabulary)
# ============================================================================

#
# Engage dispatches the common routine words (spells, maneuvers, the
# attack verbs, mstrike, hide, script, sleep, stance, wait, ambush, weed).
# This part carries the rest of bigshot 5.16's cmd_* table, read from the
# local bigshot (the Creature-migrated 5.16.0): the sorcerer and caster
# routines, the unarmed machine, wands, ranged aiming and dislodge, the
# force / eachtarget / celerity / slayer / tonis prefixes, weapon reaction,
# and the hunt_monitor lines that feed them. Each is an Action with
# bigshot's commands and gates, bounded where bigshot loops. Line
# references are to C:\Gemstone\dev\lich-5\scripts\bigshot.lic 5.16.0.
#
module EO::Engine
  module Engage
    # bigshot's globals for these routines ($bigshot_*), per fight.
    class State
      attr_accessor :reaction, :bond_returned, :archery_aim, :archery_location, :dislodge_target,
                    :unarmed_followup, :unarmed_followup_attack, :uac_aim, :wand_index, :resonance_last, :dhurl_cursor
      attr_reader :archery_stuck, :dislodge_locations, :smite_done

      def routines_reset!(moved: true)
        @reaction = nil
        @archery_aim = 0
        @archery_stuck = []
        @archery_location = nil
        @dislodge_locations = []
        @dislodge_target = nil
        @unarmed_followup = false
        @unarmed_followup_attack = ''
        @uac_aim = 0
        @dhurl_cursor = 0
        @smite_done = [] if moved || @smite_done.nil?
        @wand_index ||= 0
        @bond_returned = false
      end

      def smite_done? = (@smite_done ||= [])
    end

    module Routines
      PREFIX = /^(celerity|haste|506|slayer|240|tonis|1035)\s+(.*)/i
      ASPECTS = /^(?:jackal|wolf|lion|panther|hawk|owl|porcupine|rat|bear|burgee|mantis|serpent|spider|yierka)$/i

      module_function

      # @return [Actions::Result, nil] nil when the word is not ours
      def run(engage, world, text, line)
        target = engage.target
        policy = engage.policy
        state = engage.state
        state.routines_reset!(moved: false) if state.archery_stuck.nil?
        case text
        when /^sacrifice\b/ then Actions::Sacrifice.new(world, target: target).call
        when /^tether( recast)?\b/ then Actions::Tether.new(world, target: target, recast_on_transfer: !Regexp.last_match(1).nil?, targets_policy: engage.targets_policy).call
        when /^efury\s?(fire|cold)?/ then Actions::Efury.new(world, target: target, extra: Regexp.last_match(1)).call
        when /^phase\b/ then Actions::Phase.new(world, target: target).call
        when /^curse\s+(clumsy|weakness|darkness|itch|hex|pox|nightmare|star)$/ then Actions::Curse.new(world, target: target, kind: Regexp.last_match(1)).call
        when /^dhurl\s?(.*)?/ then dhurl(engage, world, Regexp.last_match(1))
        when /^caststop\s+(\d+)\s?(.*)?/ then Actions::CastStop.new(world, target: target, spell: Regexp.last_match(1).to_i, extra: Regexp.last_match(2)).call
        when /^depress\b/ then Actions::Depress.new(world, target: target, already: state.done_in_room?(line.raw)).call
        when /^(?:unravel|barddispel)\s?(.*)?/ then Actions::Unravel.new(world, target: target, extra: Regexp.last_match(1)).call
        when /^resonance\s+([\d\s]+)/ then resonance(engage, world, Regexp.last_match(1))
        when /^stomp\b/ then Actions::Stomp.new(world).call
        when /^leech\b/ then Actions::Leech.new(world).call
        when /^rapid(?:fire)?\s?(ignore)?/ then rapid(world, Regexp.last_match(1))
        when /^jewel (\w+)/ then Actions::Jewel.new(world, mnemonic: Regexp.last_match(1)).call
        when /^briar\s?(\w+)/ then Actions::Briar.new(world, weapon: Regexp.last_match(1)).call
        when /^assume\s?(\w+)?\s?(\w+)?/ then Actions::Assume.new(world, aspect: Regexp.last_match(1).to_s, extra: Regexp.last_match(2).to_s).call
        when /^throw\b/ then Actions::Throw.new(world, target: target).call
        when /^wield\s+(\w+)\s?(left|right)?/ then Actions::Wield.new(world, noun: Regexp.last_match(1), hand: Regexp.last_match(2).to_s).call
        when /^store\s*(left|right|both)?/ then Actions::Store.new(world, hand: Regexp.last_match(1) || 'both').call
        when /^nudgeweapons?\b/ then Actions::NudgeWeapons.new(world, stance: engage.stance, wander_stance: policy.wander_stance).call
        when /^berserk\b/ then Actions::Berserk.new(world, stance: engage.stance, wander_stance: policy.wander_stance).call
        when /^smite\b/ then Actions::Smite.new(world, target: target, state: state).call
        when /^unarmed\s+([a-z]*).?([a-z]*)?$/ then Actions::Unarmed.new(world, engage: engage, command: Regexp.last_match(1), manual_aim: Regexp.last_match(2).to_s).call
        when /^wandolier((?:\s+\w+){0,2})/ then Actions::Wandolier.new(world, target: target, policy: policy, state: state, args: Regexp.last_match(1), stance: engage.stance).call
        when /^wand\b/ then Actions::Wand.new(world, target: target, policy: policy, state: state, stance: engage.stance).call
        when /^fire\b/ then Actions::Ranged.new(world, target: target, policy: policy, state: state).call
        when /dislodge\s?(.*)/ then Actions::Dislodge.new(world, target: target, state: state, locations: Regexp.last_match(1)).call
        when /^force\s+(.*)\s+(?:till|until)\s+(\d+)/i then force(engage, world, Regexp.last_match(1), Regexp.last_match(2).to_i, line)
        when /^eachtarget\s+(.*)/i then each_target(engage, world, Regexp.last_match(1), line)
        when PREFIX then prefixed(engage, world, Regexp.last_match(1), Regexp.last_match(2), line)
        end
      end

      # cmd 3359-3387: celerity / slayer / tonis before the command.
      def prefixed(engage, world, word, rest, line)
        spell = world.spell
        case word.downcase
        when 'celerity', 'haste', '506'
          s = spell[506]
          engage.spell(world, nil, 506, '') if s && (!s.active? || s.timeleft.to_f <= 0.05)
        when 'slayer', '240'
          s = spell[240]
          s.cast if s && s.known? && s.affordable? && !world.me.cooldown_active?(s.name) && (!s.active? || s.timeleft.to_f <= 0.05)
        when 'tonis', '1035'
          s = spell[1035]
          s.cast if s && s.known? && s.affordable? && (!s.active? || s.timeleft.to_f <= 0.05)
        end
        engage.dispatch(world, rest.strip.downcase, line)
      end

      # cmd_resonance_bolt (5932): a random bolt from the list, never the
      # same one twice running.
      def resonance(engage, world, ids)
        options = ids.split.map(&:to_i).uniq - [engage.state.resonance_last]
        pick = options.sample
        return Actions::Result.new(status: :failed, reason: :no_bolt) if pick.nil?

        engage.state.resonance_last = pick
        engage.spell(world, 'incant', pick, '')
      end

      # cmd_rapid (6076)
      def rapid(world, ignore)
        s = world.spell[515]
        me = world.me
        return Actions::Result.new(status: :failed, reason: :unknown_spell) unless s&.known?
        return Actions::Result.new(status: :failed, reason: :unaffordable) unless s.affordable?
        return Actions::Result.new(status: :failed, reason: :active) if me.effect_active?('Rapid Fire') && me.buff_time_left('Rapid Fire') > 0.05
        return Actions::Result.new(status: :failed, reason: :cooldown) if me.cooldown_active?('Rapid Fire Recovery') && ignore.to_s.empty?

        Actions::Cast.new(world, spell: 515).call
      end

      # cmd_dhurl (6295): HURL at the next part in the profile's ambush
      # list, then recover the weapon.
      def dhurl(engage, world, part)
        state = engage.state
        parts = part.to_s.empty? ? Array(engage.policy.ambush) : [part]
        parts = ['chest'] if parts.empty?
        state.dhurl_cursor = 0 if state.dhurl_cursor.to_i >= parts.size
        action = Actions::Dhurl.new(world, target: engage.target, part: parts[state.dhurl_cursor.to_i], state: state)
        result = action.call
        state.dhurl_cursor = result.reason == :part_refused ? state.dhurl_cursor.to_i + 1 : 0
        result
      end

      # cmd_force (5713): repeat the command until its endroll reaches the
      # goal, thirty seconds at most, stopping on a failure line or a
      # muckle.
      RESULT = /== \+(\d+)|^\[(?:Roll|SMR|SSR) result: (\d+)/
      FAILURE = /^As you focus on your magic, your vision swims with a swirling haze of crimson|^You do not have enough stamina to attempt this maneuver\.|is lying down -- attempting to .* would be a rather awkward proposition\.|^Your magic fizzles ineffectually\.|^You are (?:still )?stunned\./
      def force(engage, world, command, goal, line)
        rolls = []
        watching = Events.on(:force_roll) { |e| rolls << e.data[:roll] }
        deadline = Time.now + 30
        result = nil
        begin
          loop do
            rolls.clear
            result = engage.dispatch(world, command.strip.downcase, line)
            return result if result.nil? || (result.failed? && result.reason != :condition)

            sleep 0.1
            return Actions::Result.new(status: :failed, reason: :force_failed) if world.me.muckled?
            return Actions::Result.new(status: :success, reason: :goal_met) if rolls.any? { |r| r >= goal }
            return Actions::Result.new(status: :failed, reason: :out_of_mana) if command =~ /^(\d+) / && !world.spell[Regexp.last_match(1).to_i]&.affordable?
            return Actions::Result.new(status: :failed, reason: :target_gone) unless Array(world.room.targets).any? { |t| t.id.to_s == engage.target&.id.to_s }
            return Actions::Result.new(status: :failed, reason: :force_timeout) if Time.now > deadline
          end
        ensure
          Events.off(watching)
        end
      end

      # cmd_eachtarget (4220): the command once at every valid creature,
      # then the game's target back on ours.
      def each_target(engage, world, command, line)
        current = engage.target
        last = nil
        Targets.candidates(world.room.targets, engage.targets_policy).each do |creature|
          Actions::Target.new(world, target: creature).call unless world.me.current_target_id.to_s == creature.id.to_s
          engage.retarget(creature)
          last = engage.dispatch(world, command.strip.downcase, line)
        end
        engage.retarget(current)
        Actions::Target.new(world, target: current).call if current && world.me.current_target_id.to_s != current.id.to_s
        last || Actions::Result.new(status: :failed, reason: :no_target)
      end
    end
  end

  module Actions
    # cmd_sacrifice (6626): two spirit, off cooldown, APPRAISE for
    # "enticingly frail", then SACRIFICE.
    class Sacrifice < Base
      include CombatRt

      def initialize(world, target:, **opts)
        super(world, target: target, **opts)
        @target = target
      end

      def preconditions
        return :dead if me.dead?
        return :low_spirit if me.spirit < 2
        return :cooldown if me.cooldown_active?('Sacrifice')

        :ok
      end

      def perform
        lines = appraise
        return Result.new(status: :failed, reason: :not_frail, line: lines.last) unless lines.any? { |l| l =~ /enticingly frail/ }

        send_and_match("sacrifice ##{@target.id}", /.*/, timeout: 3)
      end

      private

      def appraise
        ::Lich::Util.issue_command("appraise ##{@target.id}", /^The .+? is \w+ in size/, include_end: false, quiet: true, silent: true)
      rescue StandardError
        []
      end
    end

    # cmd_tether (6645): incant 706 (five hindrance retries), then hold for
    # the completion or break line up to twelve seconds; with recast, when
    # the target dies and the chains transfer, chase the new target.
    class Tether < Base
      include CombatRt

      COMPLETE = /dissolve into black mist/
      BROKEN = /^You struggle to maintain control of the dark force, but you feel it break away!|^You feel your connection to the dark presence fade away\./
      TRANSFER = /^As the signs of life fade from an? [\w\s\-]+, the tenebrous chains binding [\w\s\-]+ begin to vibrate and emit a sinister thrum that emanates through the surrounding area\.$/
      MAX_CHASE = 3

      def initialize(world, target:, recast_on_transfer: false, targets_policy: nil, chase: 0, **opts)
        super(world, target: target, **opts)
        @target = target
        @recast = recast_on_transfer
        @targets_policy = targets_policy || Targets::Policy.new
        @chase = chase
      end

      def preconditions
        return :dead if me.dead?

        s = @world.spell[706]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        s = @world.spell[706]
        answer = nil
        5.times do
          answer = s.force_incant(nil, COMPLETE)
          return Result.new(status: :success, reason: :complete, line: answer.to_s) if answer.to_s =~ COMPLETE
          break unless answer.to_s =~ /Spell Hindrance/i
        end
        state = :running
        transferred = false
        deadline = clock_now + 12
        until clock_now > deadline || interrupted?
          line = next_line
          if line.nil?
            break unless target_still_live?

            sleep 0.5
            next
          end
          if line =~ COMPLETE || line =~ BROKEN
            state = :complete
            break
          elsif line =~ TRANSFER
            transferred = true
            break
          end
        end
        return Result.new(status: :success, reason: state) if state == :complete || !@recast
        return Result.new(status: :success, reason: :ended) unless transferred || !target_still_live?

        sleep 0.5 if transferred
        new_id = me.current_target_id.to_s
        return Result.new(status: :success, reason: :no_transfer) if new_id.empty? || new_id == @target.id.to_s
        return Result.new(status: :success, reason: :chase_limit) if @chase >= MAX_CHASE

        creature = Array(@world.room.targets).find { |t| t.id.to_s == new_id }
        return Result.new(status: :success, reason: :no_transfer) if creature.nil? || !Targets.valid?(creature, @world.room.targets, @targets_policy)

        Tether.new(@world, target: creature, recast_on_transfer: true, targets_policy: @targets_policy, chase: @chase + 1, interrupt: @interrupt).call
      end
    end

    # cmd_efury (6095): incant 917, then hold up to twelve seconds for the
    # ground to calm, standing if knocked down.
    class Efury < Base
      include CombatRt

      COMPLETE = /The (?:floor|ground) beneath .* suddenly calms\.|Heat rises from the ground near .* causing a brief swelter\.|An icy mist rises from the ground near .* as the ground rumbles\.|The evanescent shield shrouding .* flares to life and absorbs the essence of the spell, dissipating it harmlessly\./

      def initialize(world, target:, extra: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @extra = extra
      end

      def preconditions
        return :dead if me.dead?

        s = @world.spell[917]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        answer = @world.spell[917].force_incant(@extra.to_s)
        return Result.new(status: :success, reason: :complete) if answer.to_s =~ COMPLETE

        deadline = clock_now + 12
        until clock_now > deadline || interrupted? || !target_still_live?
          line = next_line
          return Result.new(status: :success, reason: :complete, line: line) if line && line =~ COMPLETE

          send_through_ladder('stand') unless me.standing?
          sleep 0.5 if line.nil?
        end
        Result.new(status: :success, reason: :ended)
      end
    end

    # cmd_phase (4913)
    class Phase < Base
      include CombatRt

      def initialize(world, target:, **opts)
        super(world, target: target, **opts)
        @target = target
      end

      def preconditions
        return :dead if me.dead?

        s = @world.spell[704]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        @world.spell[704].force_cast("##{@target.id}")
        Result.new(status: :success, reason: :phased)
      end
    end

    # cmd_curse (4689): PREP 715 until ready, then CURSE #id <kind>.
    class Curse < Base
      include CombatRt

      def initialize(world, target:, kind:, **opts)
        super(world, target: target, **opts)
        @target = target
        @kind = kind
      end

      def preconditions
        return :dead if me.dead?
        return :star_active if @kind == 'star' && me.spell_effect_time_left('Curse of the Star (bonus)') > 0.5

        s = @world.spell[715]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        deadline = clock_now + 10
        until me.prepared_spell.to_s == 'Curse'
          return Result.new(status: :failed, reason: :prep_timeout) if clock_now > deadline
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          return Result.new(status: :failed, reason: :unaffordable) unless @world.spell[715].affordable?

          settle_rt
          send_through_ladder('release') unless me.prepared_spell.to_s == 'None'
          send_and_match('prep 715', /Your spell is ready\./, timeout: 2)
        end
        settle_rt
        send_and_match("curse ##{@target.id} #{@kind}", /.*/, timeout: 3)
      end
    end

    # cmd_dhurl (6295) one throw: HURL #id <part>; a refused part is the
    # caller's cue to move on; a throw waits out the flight and recovers.
    class Dhurl < Base
      include CombatRt

      THROWN = /With a quick flick of your wrist, you deftly send .+ into flight\.|^You throw|^You take aim and throw/
      NOTHING = /That's not going to do much\.  Try using a weapon|You find nothing recoverable/
      REFUSED = /You cannot aim that high!|does not have a head!|is already missing that!|does not have a (?:right|left) leg!|does not have a (?:right|left) arm!/i

      def initialize(world, target:, part:, state:, **opts)
        super(world, target: target, **opts)
        @target = target
        @part = part
        @state = state
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform
        @state.bond_returned = false
        result = send_and_match("hurl ##{@target.id} #{@part}", Regexp.union(THROWN, NOTHING, REFUSED), timeout: 2)
        return result unless result.success?
        return Result.new(status: :failed, reason: :part_refused, line: result.line) if result.line =~ REFUSED

        room = @world.room.id
        if result.line =~ THROWN
          hold = 6 - me.rt
          settle_rt
          sleep hold if hold.positive?
        end
        RecoverHurl.new(@world, state: @state, room: room, interrupt: @interrupt).call
      end
    end

    # cmd_recover (6343): RECOVER HURL until the weapon is back or the game
    # says there is nothing, in the room it was thrown from. The throw and
    # the recovery are one action, so we are still there; if we are not
    # (bigshot go2s back), the weapon is a disarm for Cleanse to go after.
    class RecoverHurl < Base
      ANSWERS = /You know .+ is around here somewhere, but you don't see it\.|You spy a .+ and recover it|A .+ rises out of the shadows and flies back to your waiting hand!|In order to recover your hurled weapon, you'll need to have a free hand\.|You find nothing recoverable\./

      def initialize(world, state:, room: nil, **opts)
        super(world, **opts)
        @state = state
        @room = room
      end

      def preconditions
        return :dead if me.dead?
        return :not_in_throw_room if @room && @world.room.id != @room

        :ok
      end

      def perform
        8.times do
          return Result.new(status: :success, reason: :bond_return) if @state.bond_returned
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          settle_rt
          result = send_and_match('recover hurl', ANSWERS, timeout: 5)
          return result unless result.success?
          return Result.new(status: :success, reason: :recovered, line: result.line) if result.line =~ /You spy a .+ and recover it|flies back to your waiting hand/
          return Result.new(status: :failed, reason: :not_recovered, line: result.line) if result.line =~ /free hand|nothing recoverable/

          sleep 0.5
        end
        Result.new(status: :failed, reason: :not_recovered)
      end
    end

    # cmd_caststop (4869): force_cast then STOP the spell.
    class CastStop < Base
      include CombatRt

      def initialize(world, target:, spell:, extra: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @num = spell
        @extra = extra
      end

      def preconditions
        return :dead if me.dead?

        s = @world.spell[@num]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        @world.spell[@num].force_cast("##{@target.id}", @extra.to_s)
        send_through_ladder("stop #{@num}")
        Result.new(status: :success, reason: :cast_stopped)
      end
    end

    # cmd_depress (4885): RENEW 1015, else incant it; once per room.
    class Depress < Base
      include CombatRt

      def initialize(world, target:, already: false, **opts)
        super(world, target: target, **opts)
        @target = target
        @already = already
      end

      def preconditions
        return :dead if me.dead?
        return :room_affected if @already

        s = @world.spell[1015]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        result = send_and_match('renew 1015', /Renewing "Song of Depression" for 6 mana\.|But you are not singing that spellsong\./, timeout: 3)
        if result.success? && result.line =~ /not singing/
          @world.spell[1015].force_incant if @world.spell[1015].affordable?
          return Result.new(status: :success, reason: :sung)
        end
        result.success? ? Result.new(status: :success, reason: :renewed) : result
      end
    end

    # cmd_unravel (4930): force_cast 1013 and read the song's answer.
    class Unravel < Base
      include CombatRt

      ANSWERS = Regexp.union(
        /You are already singing that spellsong\./,
        /The evanescent shield shrouding .* flares to life and absorbs the essence of the spell, dissipating it harmlessly\./,
        /You feel your song resonate around the .*, pulling at the threads of mana within\./,
        /You feel your song touch the magic surrounding the .+ and begin to resonate, pulling at the threads of the .+'s control\./,
        /The silvery tendril continues to wend its way away from the /,
        /You gain \d+ mana!/,
        /You feel your song echo around the .* as if it had entered a vast empty chamber\./,
        /The serpentine thread stretching between you and the (.*) fades, then disappears\./,
        /Your concentration on unravelling the threads of mana is broken\./,
        /A little bit late for that don't you think\?/,
        /What were you referring to\?/
      )

      def initialize(world, target:, extra: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @extra = extra
      end

      def preconditions
        return :dead if me.dead?

        s = @world.spell[1013]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        6.times do
          settle_rt
          answer = @world.spell[1013].force_cast("##{@target.id}", @extra.to_s, ANSWERS).to_s
          case answer
          when /You are already singing that spellsong\./, /The silvery tendril continues/
            send_through_ladder('stop 1013')
          when /You feel your song resonate|You feel your song touch|You gain \d+ mana!/
            settle_rt
            send_through_ladder('stop 1013')
            return Result.new(status: :success, reason: :unravelled, line: answer)
          when /concentration on unravelling .* is broken|vast empty chamber/
            return Result.new(status: :success, reason: :nothing_to_unravel, line: answer)
          when /What were you referring to\?|A little bit late/
            send_through_ladder('release')
            return Result.new(status: :failed, reason: :target_gone, line: answer)
          else
            return Result.new(status: :failed, reason: :cast_refused, line: answer)
          end
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
        end
        Result.new(status: :failed, reason: :unravel_loop)
      end
    end

    # cmd_stomp (6041): 909 up, then STOMP with five mana.
    class Stomp < Base
      include CombatRt

      def preconditions
        return :dead if me.dead?

        @world.spell[909]&.known? ? :ok : :unknown_spell
      end

      def perform
        s = @world.spell[909]
        unless s.active?
          return Result.new(status: :failed, reason: :unaffordable) unless s.affordable?

          s.force_channel
          settle_rt
        end
        return Result.new(status: :failed, reason: :low_mana) if me.mana < 5

        send_and_match('stomp', /.*/, timeout: 3)
      end
    end

    # cmd_leech (6060): 516 when its cooldown has under fifteen seconds.
    class Leech < Base
      include CombatRt

      def preconditions
        return :dead if me.dead?

        s = @world.spell[516]
        return :unknown_spell unless s&.known?
        return :cooldown unless me.cooldown_time_left('Mana Leech') < 15
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        @world.spell[516].cast
        Result.new(status: :success, reason: :leech)
      end
    end

    # cmd_jewel (5164): GEMSTONE ACTIVATE by mnemonic, off cooldown.
    class Jewel < Base
      include CombatRt

      JEWELS = {
        'bloodboil' => 'Blood Boil', 'spellblade' => "Spellblade's Fury", 'arcascend' => "Arcanist's Ascendancy",
        'geospite' => "Geomancer's Spite", 'forceofwill' => 'Force of Will', 'arcaneintensity' => 'Arcane Intensity',
        'arcaneopus' => 'Arcane Opus', 'bloodsiphon' => 'Blood Siphon', 'bloodwell' => 'Blood Wellspring',
        'epossess' => 'Evanescent Possession', 'manawellspring' => 'Mana Wellspring', 'spiritwell' => 'Spirit Wellspring',
        'stamwell' => 'Stamina Wellspring', 'terrortribute' => "Terror's Tribute", 'arcblade' => "Arcanist's Blade",
        'arcwill' => "Arcanist's Will", 'imaerabalm' => "Imaera's Balm", 'reckless' => 'Reckless Precision',
        'unearthchains' => 'Unearthly Chains', 'witchhunt' => "Witchhunter's Ascendancy", 'manashield' => 'Mana Shield',
        'arcaneaegis' => 'Arcane Aegis'
      }.freeze
      ANSWERS = Regexp.union(
        /^That property isn't ready yet\./, /^You don't have that property equipped\./, /^You fail to find a target\./,
        /^You have not yet unlocked Gemstones\./, Cast::CAST, Cast::BLOCKED, Cast::NO_TARGET, Cast::CANNOT_PREPARE, Cast::FIZZLED,
        /keeps? the spell from working\./, /^As you focus on your magic, your vision swims/, /^And give yourself away!  Never!$/,
        /^You are unable to do that right now\.$/, /^You don't seem to be able to move to do that\.$/
      )

      def initialize(world, mnemonic:, **opts)
        super(world, **opts)
        @mnemonic = mnemonic.to_s.downcase
      end

      def preconditions
        return :dead if me.dead?
        return :unknown_jewel unless JEWELS.key?(@mnemonic)
        return :cooldown if me.cooldown_active?(JEWELS[@mnemonic])

        :ok
      end

      def perform = send_and_match("gemstone activate #{@mnemonic}", ANSWERS, timeout: 2)
    end

    # cmd_briar (5665): MEASURE each briar weapon, RAISE it at 100%.
    class Briar < Base
      def initialize(world, weapon:, **opts)
        super(world, **opts)
        @weapon = weapon
      end

      def preconditions
        return :dead if me.dead?
        return :active if me.spell_active?(9105)

        :ok
      end

      def perform
        items = [@world.hands.right, @world.hands.left].select { |h| h&.id && h.noun.to_s == @weapon }
        items += inventory.select { |i| i.noun.to_s == @weapon }
        return Result.new(status: :failed, reason: :no_weapon) if items.empty?

        raised = 0
        items.each do |item|
          lines = measure(item.id)
          next unless lines.any? { |l| l =~ /to be about (\d+) percent\./i && Regexp.last_match(1).to_i == 100 }

          send_through_ladder("raise ##{item.id}")
          raised += 1
        end
        Result.new(status: :success, reason: raised.positive? ? :raised : :not_ready)
      end

      private

      def inventory
        Array(::GameObj.inv)
      rescue StandardError
        []
      end

      def measure(id)
        ::Lich::Util.quiet_command_xml("measure ##{id}", /^You gaze intently|^Now, why are you trying to measure/, /<prompt time=/)
      rescue StandardError
        []
      end
    end

    # cmd_assume (5603): PREP or EVOKE 650, ASSUME the first aspect, then
    # the second, or CAST the prepared 650.
    class Assume < Base
      include CombatRt

      ASSUMED = /^You concentrate your focus upon the Aspect|^You feel that you will not be able to fully concentrate upon the Aspect/i

      def initialize(world, aspect:, extra:, **opts)
        super(world, **opts)
        @aspect = aspect.to_s.downcase
        @extra = extra.to_s.downcase
      end

      def preconditions
        return :dead if me.dead?
        return :unknown_spell unless @world.spell[650]&.known?
        return :bad_aspect unless @aspect =~ Engage::Routines::ASPECTS
        return :cooldown if me.spell_active?("Aspect of the #{@aspect.capitalize} Cooldown") && me.spell_active?("Aspect of the #{@extra.capitalize} Cooldown")
        return :active if me.effect_active?("Aspect of the #{@aspect.capitalize}") || me.effect_active?("Aspect of the #{@extra.capitalize}")

        :ok
      end

      def perform
        s = @world.spell[650]
        prep = me.prepared_spell.to_s
        send_through_ladder('release') if prep != 'None' && prep != 'Assume Aspect'
        settle_rt
        first = false
        unless me.effect_active?('Assume Aspect') || me.effect_active?('650') || me.prepared_spell.to_s == 'Assume Aspect'
          if @extra =~ /evoke/
            s.force_evoke if s.affordable?
          else
            send_through_ladder('prep 650') if s.affordable?
          end
          first = true
        end
        return Result.new(status: :failed, reason: :not_prepared) unless me.prepared_spell.to_s == 'Assume Aspect' || me.effect_active?('Assume Aspect') || me.effect_active?('650')

        if !me.spell_active?("Aspect of the #{@aspect.capitalize} Cooldown") && (first || me.mana >= 25)
          send_and_match("assume #{@aspect}", ASSUMED, timeout: 1)
          Result.new(status: :success, reason: :assumed)
        elsif !me.spell_active?("Aspect of the #{@extra.capitalize} Cooldown") && (first || me.mana >= 25)
          return Result.new(status: :success, reason: :evoked) if @extra =~ /evoke/

          send_and_match("assume #{@extra}", ASSUMED, timeout: 1)
          Result.new(status: :success, reason: :assumed)
        elsif me.prepared_spell.to_s == 'Assume Aspect'
          send_through_ladder('cast') if s.affordable?
          Result.new(status: :success, reason: :cast)
        else
          Result.new(status: :failed, reason: :cooldown)
        end
      end
    end

    # cmd_throw (5695): stow, THROW #id, refill; never at a creature lying down.
    class Throw < Base
      include CombatRt

      def initialize(world, target:, **opts)
        super(world, target: target, **opts)
        @target = target
      end

      def preconditions
        return :dead if me.dead?
        return :target_down if @target.status.to_s == 'lying down'

        :ok
      end

      def perform
        send_through_ladder('stow all')
        result = send_and_match("throw ##{@target.id}", /^You attempt to throw a .*!$/, timeout: 1)
        settle_rt
        ::Lich::Stash.equip_hands(both: true) rescue nil
        result
      end
    end

    # cmd_wield (4564): STORE the hand, then REMOVE or GET the item.
    class Wield < Base
      def initialize(world, noun:, hand: '', **opts)
        super(world, **opts)
        @noun = noun
        @hand = hand.to_s
      end

      def preconditions
        return :dead if me.dead?
        return :already_wielded if (@hand.empty? || @hand == 'right') && @world.hands.right.noun.to_s == @noun
        return :already_wielded if @hand == 'left' && @world.hands.left.noun.to_s == @noun

        :ok
      end

      def perform
        send_through_ladder(@hand == 'left' ? 'store left' : 'store right')
        worn = me.inventory_nouns.include?(@noun)
        send_through_ladder(worn ? "remove my #{@noun}" : "get my #{@noun}")
        Result.new(status: :success, reason: :wielded)
      end
    end

    # cmd_store (4585)
    class Store < Base
      def initialize(world, hand: 'both', **opts)
        super(world, **opts)
        @hand = hand.to_s.empty? ? 'both' : hand.to_s
      end

      def preconditions
        return :dead if me.dead?
        return :empty if @hand == 'right' && @world.hands.right.id.nil?
        return :empty if @hand == 'left' && @world.hands.left.id.nil?
        return :empty if @hand == 'both' && @world.hands.right.id.nil? && @world.hands.left.id.nil?

        :ok
      end

      def perform
        send_through_ladder("store #{@hand}")
        Result.new(status: :success, reason: :stored)
      end
    end

    # cmd_nudge_weapons (6592): carry each weapon on the floor one room
    # over and come back, sheathing first when both hands are full.
    class NudgeWeapons < Base
      WEAPONS = /axe|scythe|pitchfork|falchion|sword|lance|dagger|estoc|handaxe|katana|katar|gauche|rapier|scimitar|whip-blade|cudgel|crowbill|whip|mace|star|hammer|claidhmore|flail|flamberge|maul|pick|staff|mattock/
      REVERSE = { 'north' => 'south', 'south' => 'north', 'east' => 'west', 'west' => 'east', 'northeast' => 'southwest', 'southwest' => 'northeast',
                  'northwest' => 'southeast', 'southeast' => 'northwest', 'up' => 'down', 'down' => 'up', 'out' => 'out' }.freeze

      def initialize(world, stance: nil, wander_stance: nil, **opts)
        super(world, **opts)
        @stance = stance
        @wander_stance = wander_stance
      end

      def preconditions
        return :dead if me.dead?
        return :no_exit if Array(@world.room.exits).empty?

        :ok
      end

      def perform
        moved = 0
        Array(@world.room.loot).select { |i| i.noun.to_s =~ WEAPONS }.each do |item|
          @stance&.call(@wander_stance) if @wander_stance
          sheathed = false
          if @world.hands.right.id && @world.hands.left.id
            sheathed = true
            send_through_ladder('sheath')
            return Result.new(status: :failed, reason: :hands_full) if @world.hands.right.id && @world.hands.left.id
          end
          dir = Array(@world.room.exits).first
          back = REVERSE[dir]
          return Result.new(status: :failed, reason: :no_way_back) if back.nil?

          send_through_ladder("get ##{item.id}")
          there = Move.new(@world, way: dir, interrupt: @interrupt).call
          return Result.new(status: :failed, reason: :could_not_step, line: dir) unless there.success?

          send_through_ladder("drop ##{item.id}")
          home = Move.new(@world, way: back, interrupt: @interrupt).call
          return Result.new(status: :failed, reason: :could_not_return, line: back) unless home.success?

          send_through_ladder('gird') if sheathed
          moved += 1
        end
        Result.new(status: :success, reason: moved.positive? ? :nudged : :nothing_to_nudge)
      end
    end

    # cmd_berserk (6510): wander stance and 9607 with twenty stamina, else
    # TARGET RANDOM and KILL.
    class Berserk < Base
      include CombatRt

      def initialize(world, stance: nil, wander_stance: nil, **opts)
        super(world, **opts)
        @stance = stance
        @wander_stance = wander_stance
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        if me.stamina >= 20
          @stance&.call(@wander_stance) if @wander_stance
          @world.spell[9607].cast
          sleep 5
          deadline = clock_now + 120
          sleep 0.5 while me.spell_active?(9607) && clock_now < deadline && !interrupted?
          Result.new(status: :success, reason: :berserked)
        else
          send_through_ladder('target random')
          send_through_ladder('kill')
          Result.new(status: :success, reason: :kill_random)
        end
      end
    end

    # cmd_volnsmite (5433): SMITE an undead or noncorporeal target until it
    # is smote or the game says it is done.
    class Smite < Base
      include CombatRt

      def initialize(world, target:, state:, **opts)
        super(world, target: target, **opts)
        @target = target
        @state = state
      end

      def preconditions
        return :dead if me.dead?
        return :already_smote if @state.smite_done?.include?(@target.id.to_s)

        types = @target.type.to_s.split(',')
        return :not_undead unless types.include?('undead') || types.include?('noncorporeal')

        :ok
      end

      def perform
        6.times do
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          break unless target_still_live?

          result = send_and_match("smite ##{@target.id}", /^Roundtime|^What were you referring to\?$|^It looks like somebody already did the job for you\.$/, timeout: 1)
          if result.success? && result.line =~ /already did the job/
            @state.smite_done? << @target.id.to_s
            return Result.new(status: :success, reason: :already_smote)
          end
          return Result.new(status: :failed, reason: :referent_missing) if result.success? && result.line =~ /What were you/
          return Result.new(status: :success, reason: :smote) if @state.smite_done?.include?(@target.id.to_s)

          sleep 1
        end
        Result.new(status: :success, reason: :smite_ended)
      end
    end

    # cmd_ranged (6375): AIM at the profile's next part (skipping one an
    # arrow is stuck in, or a head or eye the target has lost), FIRE, stow
    # a weapon the game refuses to fire, rest on unblessed ammo.
    class Ranged < Base
      include CombatRt

      ANSWERS = /round(?:time)?|You cannot|Could not find|seconds|Get what\?|but it has no effect/i

      def initialize(world, target:, policy:, state:, **opts)
        super(world, target: target, **opts)
        @target = target
        @policy = policy
        @state = state
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?
        return :too_injured unless me.able_to_use_ranged? # Lich's Injured: arms and hands

        :ok
      end

      def perform
        aim
        result = send_and_match("fire ##{@target.id}", ANSWERS, timeout: 2)
        return result unless result.success?

        line = result.line
        if line =~ /You cannot fire/
          stow_weapon
          Result.new(status: :failed, reason: :cannot_fire, line: line)
        elsif line =~ /but it has no effect/
          Events.emit(:ammo_no_effect)
          Result.new(status: :failed, reason: :ammo_no_effect, line: line)
        elsif line =~ /round(?:time)?/i
          @state.archery_aim = 0
          @state.archery_stuck.clear
          result
        else
          Result.new(status: :failed, reason: :fire_refused, line: line)
        end
      end

      private

      def aim
        parts = Array(@policy.archery_aim)
        return if parts.empty?

        @state.archery_aim = @state.archery_aim.to_i + 1 if @state.archery_stuck.any? { |s| @state.archery_location && s =~ /#{Regexp.escape(@state.archery_location)}/i }
        if @state.archery_aim > parts.length
          @state.archery_aim = 0
          @state.archery_stuck.clear
        end
        part = parts[@state.archery_aim]
        return if part.nil?

        vitals_skip(parts) if %w[head neck left\ eye right\ eye].include?(part)
        part = parts[@state.archery_aim]
        return if part.nil?
        return if @state.archery_location && part =~ /#{Regexp.escape(@state.archery_location)}/i

        send_through_ladder("aim #{part}")
      end

      # check_target_vitals (6234): skip a part the target has already lost
      def vitals_skip(parts)
        info = vitals
        return if info.nil?

        part = parts[@state.archery_aim]
        lost = (part == 'head' && info =~ /severe head trauma and bleeding from .* ears/) ||
               (part == 'neck' && info =~ /snapped bones and serious bleeding from .* neck/) ||
               (part == 'left eye' && info =~ /blinded left eye/) ||
               (part == 'right eye' && info =~ /blinded right eye/)
        @state.archery_aim += 1 if lost
      end

      def vitals
        lines = ::Lich::Util.issue_command("look ##{@target.id}", /You see|I could not find/, quiet: true, silent: true)
        line = lines.find { |l| l =~ %r{(?:he|she|it)</a><popBold/> has (.*)}i }
        line && line[%r{(?:he|she|it)</a><popBold/> has (.*)}i, 1]
      rescue StandardError
        nil
      end

      def stow_weapon
        weapon = @world.hands.right
        return if weapon.id.nil?

        result = send_and_match("stow ##{weapon.id}", /put|closed/, timeout: 3)
        return unless result.success? && result.line =~ /closed/ && @policy.ammo_container

        container = me.inventory_named(@policy.ammo_container)
        return if container.nil?

        stash_into(container, weapon)
      end

      # Lich's Stash (lich-5 #1579): open the container, then drag the
      # weapon in and wait for it to leave the hand. False when either
      # step fails, where the raw open-and-put pair assumed success.
      def stash_into(container, weapon)
        ::Lich::Stash.open_container(container.id) && ::Lich::Stash.add_to_bag(container, weapon) ? true : false
      rescue StandardError
        false
      end
    end

    # cmd_dislodge (6430): CMAN DISLODGE the first listed location an arrow
    # is stuck in, on the creature it stuck in.
    class Dislodge < Base
      include CombatRt

      ANSWERS = /attempting to dislodge|suitable weapons lodged|You can't reach|awkward proposition|little bit late|still stunned|too injured|what\?|round(?:time)?|You cannot|Could not find|seconds|You manage to dislodge|You skillfully wrench/i

      def initialize(world, target:, state:, locations:, **opts)
        super(world, target: target, **opts)
        @target = target
        @state = state
        @locations = locations.to_s.split(/ /, 9)
      end

      def preconditions
        return :dead if me.dead?
        return :unavailable unless cman_available?
        return :wrong_target if @target.id.to_s != @state.dislodge_target.to_s

        @where = @locations.find { |loc| @state.dislodge_locations.include?(loc) }
        @where ? :ok : :nothing_lodged
      end

      def perform
        result = send_and_match("cman dislodge ##{@target.id} #{@where}", ANSWERS, timeout: 2)
        return result unless result.success?

        if result.line =~ /You manage to dislodge|You skillfully wrench/
          @state.dislodge_locations.delete(@where)
          if @target.status.to_s =~ /dead|gone/
            @state.dislodge_locations.clear
            @state.dislodge_target = nil
          end
          Result.new(status: :success, reason: :dislodged, line: result.line)
        else
          Result.new(status: :failed, reason: :dislodge_refused, line: result.line)
        end
      end

      private

      def cman_available?
        ::Lich::Gemstone::CMan.available?('Dislodge')
      rescue StandardError
        false
      end
    end

    # cmd_wand (5950): the next fresh wand from its container into hand,
    # WAVE it at the target in the offensive stance, drop or store a wand
    # that gave nothing.
    class Wand < Base
      include CombatRt

      WAVED = /d100|You hurl|is already dead|You do not see that here|You are in no condition|I could not find/

      def initialize(world, target:, policy:, state:, stance: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @policy = policy
        @state = state
        @stance = stance
      end

      def preconditions
        return :dead if me.dead?
        return :no_container if @policy.fresh_wand_container.to_s.empty?
        return :no_wands if Array(@policy.wand).empty?

        :ok
      end

      def perform
        wand = current_wand
        until in_hand?(wand)
          result = send_and_match("get #{wand} from my #{@policy.fresh_wand_container}", /You remove|You slip|Get what/, timeout: 3)
          return Result.new(status: :failed, reason: :wand_timeout) unless result.success?

          if result.line =~ /Get what/
            @state.wand_index = @state.wand_index.to_i + 1
            wand = current_wand
            if wand.nil?
              Events.emit(:no_fresh_wands)
              return Result.new(status: :failed, reason: :no_fresh_wands)
            end
          end
        end

        @stance&.call('offensive')
        result = send_and_match("wave my #{wand} at ##{@target.id}", WAVED, timeout: 3)
        @stance&.call(@policy.hunting_stance) if @policy.hunting_stance
        if result.success? && result.line =~ /You are in no condition/
          Events.emit(:too_injured_for_wands)
          return Result.new(status: :failed, reason: :too_injured, line: result.line)
        end
        unless result.success?
          if @policy.dead_wand_container.to_s.empty?
            send_through_ladder("drop my #{wand}")
          else
            send_through_ladder("put my #{wand} in my #{@policy.dead_wand_container}")
          end
          return Result.new(status: :failed, reason: :dead_wand)
        end
        result
      end

      private

      def current_wand = Array(@policy.wand)[@state.wand_index.to_i]

      def in_hand?(wand)
        return false if wand.nil?

        pattern = /#{wand.split(' ').join('.*?')}/i
        "#{@world.hands.right.name}#{@world.hands.left.name}" =~ pattern ? true : false
      end
    end

    # cmd_wandolier (5995): the wand from hand or the RESERVE list, else
    # from the container (RUB it when empty), RESERVE it, WAVE it.
    class Wandolier < Base
      include CombatRt

      WAVED = /d100|You hurl|is already dead|You do not see that here|You are in no condition|I could not find|What were you referring to/
      STANCES = %w[offensive advance forward neutral guarded defensive].freeze

      def initialize(world, target:, policy:, state:, args: '', stance: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @policy = policy
        @state = state
        @stance = stance
        tokens = args.to_s.downcase.split(/\s+/).reject(&:empty?)
        @noreserve = tokens.include?('noreserve')
        @wave_stance = (tokens & STANCES).first || 'offensive'
      end

      def preconditions
        return :dead if me.dead?
        return :no_container if @policy.fresh_wand_container.to_s.empty?
        return :no_wands if Array(@policy.wand).empty?

        :ok
      end

      def perform
        wand_name = Array(@policy.wand)[@state.wand_index.to_i]
        pattern = /#{wand_name.split(' ').join('.*?')}/i
        send_through_ladder('reserve list') if reserve.nil?
        wand = nil
        6.times do
          wand = ([@world.hands.right, @world.hands.left] + Array(reserve)).compact.find { |o| o.id && o.name.to_s =~ pattern }
          break if wand

          result = send_and_match("get #{wand_name} from my #{@policy.fresh_wand_container}", /You (?:remove|slip|slide)|Get what/, timeout: 3)
          return Result.new(status: :failed, reason: :wand_timeout) unless result.success?

          send_through_ladder("rub my #{@policy.fresh_wand_container}") if result.line =~ /Get what/
        end
        return Result.new(status: :failed, reason: :no_wand) if wand.nil?

        send_through_ladder("reserve ##{wand.id}") if !@noreserve && [@world.hands.right, @world.hands.left].any? { |h| h.id.to_s == wand.id.to_s }
        @stance&.call(@wave_stance)
        result = send_and_match("wave ##{wand.id}", WAVED, timeout: 3)
        @stance&.call(@policy.hunting_stance) if @policy.hunting_stance
        if result.success? && result.line =~ /You are in no condition/
          Events.emit(:too_injured_for_wands)
          return Result.new(status: :failed, reason: :too_injured, line: result.line)
        end
        send_through_ladder('reserve list') if result.success? && result.line =~ /What were you referring to/
        result
      end

      private

      def reserve
        ::GameObj.reserve
      rescue StandardError
        nil
      end
    end

    # cmd_unarmed (5470): smite a noncorporeal at tier 3, mstrike unless
    # the profile forbids it, then the tier-3 attack, the advertised
    # follow-up, or the command, at the next aim part; read the answer for
    # the tier, the follow-up, a lost part, roundtime.
    class Unarmed < Base
      include CombatRt

      def initialize(world, engage:, command:, manual_aim: '', **opts)
        super(world, target: engage.target, **opts)
        @engage = engage
        @target = engage.target
        @command = command
        @manual_aim = manual_aim.to_s
        @policy = engage.policy
        @state = engage.state
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform
        @state.uac_aim = -1 if !@manual_aim.empty? && @state.uac_aim.to_i.zero?
        if @policy.uac_smite && @target.type.to_s.split(',').include?('noncorporeal') && @state.unarmed_tier == 3 && @world.spell[9821]&.known?
          Smite.new(@world, target: @target, state: @state, interrupt: @interrupt).call unless @state.smite_done?.include?(@target.id.to_s)
        end

        struck = false
        unless @policy.uac_mstrike
          word = @policy.tier3.to_s.empty? ? @command : @policy.tier3
          mstrike = Mstrike.new(@world, policy: @engage.mstrike_policy, target: @target, attack: word, targets_policy: @engage.targets_policy, interrupt: @interrupt).call
          struck = mstrike.success?
          sleep 0.3
        end
        return Result.new(status: :success, reason: :mstrike) if struck

        word = if @state.unarmed_tier == 3 && !@state.unarmed_followup && !@policy.tier3.to_s.empty? then @policy.tier3
               elsif @state.unarmed_followup then @state.unarmed_followup_attack
               else @command
               end
        result = swing(word)
        return result unless result.success?

        read_answer(word)
      end

      private

      def aim_part
        return @manual_aim unless @manual_aim.empty?

        Array(@policy.aim)[@state.uac_aim.to_i]
      end

      def swing(word)
        part = aim_part
        text = part.to_s.empty? ? "#{word} ##{@target.id}" : "#{word} ##{@target.id} #{part}"
        first = send_through_ladder(text)
        first.is_a?(Result) ? first : Result.new(status: :success, line: first)
      end

      # the read loop (5522-5570)
      def read_answer(word)
        deadline = clock_now + 5
        reason = :swung
        loop do
          line = next_line
          if line.nil?
            break if clock_now > deadline || interrupted?

            sleep 0.1
            next
          end
          case line
          when /You have (decent|good|excellent) positioning/
            @state.unarmed_tier = { 'decent' => 1, 'good' => 2, 'excellent' => 3 }[Regexp.last_match(1)]
          when /.* = .* d100: .* = -?(\d+)$/
            @state.unarmed_followup = false if @state.unarmed_followup && Regexp.last_match(1).to_i > 100
          when /Strike leaves foe vulnerable to a followup (.*) attack!/
            @state.unarmed_followup = true
            @state.unarmed_followup_attack = Regexp.last_match(1)
          when /You fail to find an opening for your strike\./
            @state.uac_aim = @state.uac_aim.to_i + 1
          when /You cannot aim that high!|is already missing that!|does not have/
            @state.uac_aim = @state.uac_aim.to_i + 1
            swing(word)
          when /Roundtime:/i
            @state.uac_aim = 0
            break
          when /^Try standing up first\.$|[wW]ait \d+ sec.*|Sorry,|You can't do that while entangled in a web|You are still stunned|from here\.  Perhaps you should try throwing or shooting something at it\./
            reason = :refused
            break
          when /You don't seem to be able to move(?: your legs)? to do that\./
            Events.emit(:rooted)
            reason = :rooted
            break
          when /You are unable to muster the will to attack anything\.|Your rage causes you to use all of your skill in an all out attack!/
            s = @world.spell[1201]
            s.cast if s&.known? && s.affordable?
            reason = :soothed
            break
          when /You currently have no valid target\.  You will need to specify one\.|^It looks like somebody already did the job for you\.$|What were you referring to/
            @state.unarmed_tier = 1
            @state.unarmed_followup = false
            @state.unarmed_followup_attack = ''
            reason = :target_gone
            break
          end
          unless target_still_live?
            @state.unarmed_tier = 1
            @state.unarmed_followup = false
            reason = :target_gone
            break
          end
        end
        Result.new(status: reason == :refused ? :failed : :success, reason: reason)
      end
    end

    # perform_reaction (8062): WEAPON <reaction> the game offered, in the
    # hunting stance, then back.
    class Reaction < Base
      include CombatRt

      def initialize(world, reaction:, stance: nil, hunting_stance: nil, **opts)
        super(world, **opts)
        @reaction = reaction
        @stance = stance
        @hunting_stance = hunting_stance
      end

      def preconditions = me.dead? ? :dead : :ok

      def perform
        original = me.stance_text
        @stance&.call(@hunting_stance) if @hunting_stance
        result = send_and_match("weapon #{@reaction}", /.*/, timeout: 3)
        @stance&.call(original) if original
        result
      end
    end
  end
end
