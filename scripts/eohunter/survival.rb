# frozen_string_literal: true

# ============================================================================
# survival (bigshot's dead_man_switch, stand, escape_rooms,
#           check_for_deaders_prone, the rooted and too-many-items lines)
# ============================================================================

#
# bigshot has no survival layer; it has a stand at the top of its main
# loop (8219), escape_rooms and check_for_deaders_prone before every
# command (3299-3305), and a dead_man_switch thread (5664) that kills,
# departs or quits when we die. The engine's Survival is those as the
# behavior at priority 0: nothing else runs while we are dead, in an
# escape room, on the ground, or standing over a dead player. Rules and
# bigshot line references in hunting-engine-plan.md, "Survival".
#
module EO::Engine
  module Survival
    # stand_stance / pull / deader / dead_man_switch / depart from the
    # profile (2872-2959). on_death is :stop (kill the script), :depart
    # (DEPART and let the script rest and restart) or :quit (GSF's switch).
    Policy = Struct.new(:stand_stance, :pull, :deader, :group_deader, :on_death, keyword_init: true) do
      def initialize(stand_stance: 'defensive', pull: true, deader: false, group_deader: false, on_death: :stop) = super
    end

    DOWN = /sitting|^lying|prone/
    STUNNED = /webbed|sleeping|stunned|frozen|immobilized|held in place|horrified|staggered/i

    module Predicates
      module_function

      # Players here on the ground and alive (3266): with +pull+ any of
      # them while an aggressive creature is up, group members always.
      def to_pull(world, policy)
        players = Array(world.room.players).select { |p| p.status.to_s =~ DOWN && p.status.to_s !~ /dead/ }
        return players if policy.pull && Array(world.room.targets).any? { |t| t.type.to_s =~ /aggressive npc/ }

        nouns = world.group_nouns
        players.select { |p| nouns.include?(p.noun.to_s) }
      end

      # A dead player here (3944), with the deader toggle; a dead group
      # member (3952) with group_deader. Both are the leader's checks: a
      # follower never stops for a deader.
      def deader?(world, policy, follower: false)
        return false if follower

        dead = Array(world.room.players).select { |p| p.status.to_s =~ /dead/ }
        return true if policy.deader && dead.any?

        policy.group_deader && dead.any? { |p| world.group_nouns.include?(p.noun.to_s) }
      end

      # group_member_stunned? (5632): us, or a group member by status.
      def group_member_stunned?(world)
        me = world.me
        return true if me.webbed? || me.sleeping? || me.stunned? || (me.respond_to?(:frozen?) && me.frozen?)

        nouns = world.group_nouns
        Array(world.room.players).any? { |p| p.status.to_s =~ STUNNED && nouns.include?(p.noun.to_s) }
      end

      # In priority order: :dead, :trapped (an escape room), :deader (a dead
      # player to stop for), :prone (not standing, unless resting), :pull.
      def reason(world, policy, resting: false, follower: false)
        me = world.me
        return :dead if me.dead?
        return :trapped if Actions::Escape.kind_for(world.room.title)
        return :deader if deader?(world, policy, follower: follower)
        return :prone if !me.standing? && !resting && !me.muckled?
        return :pull if to_pull(world, policy).any?

        nil
      end
    end
  end

  module Actions
    # stand (5901): drop to stand_stance, STAND until standing, restore the
    # stance we had. Never in the ooze. Bounded where bigshot loops.
    class Stand < Base
      ATTEMPTS = 3

      def initialize(world, stance: nil, stand_stance: 'defensive', attempts: ATTEMPTS, timeout: 3, **opts)
        super(world, **opts)
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @stand_stance = stand_stance
        @attempts = attempts
        @timeout = timeout
      end

      def preconditions
        return :dead if me.dead?
        return :already_standing if me.standing?
        return :in_ooze if @world.room.title.to_s.include?('Ooze, Innards')

        :ok
      end

      def perform
        # Lich's Stance.at?: already in the stand stance means nothing to
        # change and nothing to restore (a regex on the stance word read
        # "advance" as "advanced" and could not read a percentage stance).
        restore = @stand_stance && !stance_at?(@stand_stance) ? me.stance_text : nil
        @stance.call(@stand_stance) if restore
        result = nil
        @attempts.times do
          result = send_and_observe('stand', timeout: @timeout) { me.standing? }
          break if result.success? || result.status == :failed
        end
        @stance.call(restore) if restore
        result.success? ? result : Result.new(status: :failed, reason: :still_down, line: result.line)
      end

      def stance_at?(name)
        ::Lich::Gemstone::Stance.at?(name) ? true : false
      rescue StandardError
        false
      end
    end

    # PULL a player to their feet (3267), confirmed on the game's answer.
    class Pull < Base
      ANSWERS = /^You (?:help|pull|grab|assist)|is already standing|doesn't need your help|^What were you referring to\?|^I could not find|^Roundtime/

      def initialize(world, player:, timeout: 3, **opts)
        super(world, **opts)
        @player = player
        @timeout = timeout
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform = send_and_match("pull #{@player.noun}", ANSWERS, timeout: @timeout)
    end

    # dead_man_switch (5677): DEPART twice, DEPART CONFIRM twice. The
    # rest, ewaggle and the restart are the script's.
    class Depart < Base
      ANSWERS = /^You have departed|^Your spirit|^You feel|^What were you|^But you are not dead/i

      def preconditions = me.dead? ? :ok : :alive

      def dead_ok? = true

      def perform
        last = nil
        2.times { last = send_through_ladder('depart') }
        2.times { last = send_through_ladder('depart confirm') }
        last.is_a?(Result) ? last : Result.new(status: :success, reason: :departed, line: last)
      end
    end
  end

  module Behaviors
    # Priority 0: the things nothing else may run through.
    class Survival < Behavior
      attr_reader :reason

      # @param policy [Survival::Policy]
      # @param resting [#call] -> Boolean, true while Rest holds the character down
      # @param stance [#call] (name) -> Boolean
      # @param follower [Boolean] a follower never stops for a deader
      def initialize(policy:, resting: nil, stance: nil, follower: false)
        super()
        @policy = policy
        @resting = resting || -> { false }
        @stance = stance
        @follower = follower
        @rooted = false
        @announced_dead = false
        @announced_deader = false
        Events.on(:rooted) { @rooted = true }
        Events.on(:unrooted) { @rooted = false }
        Events.on(:entered_room) { @rooted = false; @announced_deader = false }
      end

      def priority = 0

      # Held by a snake or a root: kicks become punches (bigshot cmd 3318).
      def rooted? = @rooted

      def wants_control?(world)
        @reason = EO::Engine::Survival::Predicates.reason(world, @policy, resting: @resting.call, follower: @follower)
        !@reason.nil?
      end

      def tick(world)
        case @reason || EO::Engine::Survival::Predicates.reason(world, @policy, resting: @resting.call, follower: @follower)
        when :dead then died(world)
        when :trapped then Actions::Escape.new(world).call
        when :deader then deader(world)
        when :prone then Actions::Stand.new(world, stance: @stance, stand_stance: @policy.stand_stance).call
        when :pull then Actions::Pull.new(world, player: EO::Engine::Survival::Predicates.to_pull(world, @policy).first).call
        end
      end

      private

      def died(world)
        unless @announced_dead
          @announced_dead = true
          Events.emit(:died, room: world.room.id, on_death: @policy.on_death)
        end
        case @policy.on_death
        when :depart then Actions::Depart.new(world).call
        when :quit then Actions::Command.new(world, command: 'quit', allow_dead: true).call
        else Actions::Result.new(status: :failed, reason: :dead)
        end
      end

      # bigshot pauses itself and says ";u bigshot" to go on (3280). The
      # engine reports it once per room and stays here until the script
      # decides; the pause is the script's.
      def deader(world)
        unless @announced_deader
          @announced_deader = true
          Events.emit(:deader, room: world.room.id, players: Array(world.room.players).select { |p| p.status.to_s =~ /dead/ }.map(&:noun))
        end
        Actions::Result.new(status: :failed, reason: :deader)
      end
    end
  end
end
