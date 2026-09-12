# frozen_string_literal: true

# ============================================================================
# survival (bigshot's dead_man_switch, stand, escape_rooms,
#           check_for_deaders_prone, the rooted and too-many-items lines)
# ============================================================================

#
# bigshot has no survival layer; it has a stand at the top of its main
# loop, escape_rooms and check_for_deaders_prone before every
# command, and a dead_man_switch thread that kills,
# departs or quits when we die. The engine's Survival is those as the
# behavior at priority 0: nothing else runs while we are dead, in an
# escape room, on the ground, or standing over a dead player. Rules and
# bigshot line references in hunting-engine-plan.md, "Survival".
#
module EO::Engine
  # The things nothing else may run through: dead, an escape room, a dead
  # player to stop for, on the ground, a player to pull up. The Policy is
  # the profile's survival settings; Predicates decide in priority order.
  #
  # @bigshot dead_man_switch
  # @bigshot stand
  module Survival
    # stand_stance / pull / deader / dead_man_switch / depart from the
    # profile. on_death is :stop (kill the script), :depart
    # (DEPART and let the script rest and restart) or :quit (GSF's switch).
    #
    # @bigshot profile settings
    Policy = Struct.new(:stand_stance, :pull, :deader, :group_deader, :on_death, keyword_init: true) do
      # @param stand_stance [String] the stance to stand in
      # @param pull [Boolean] pull any downed player while a creature is up
      # @param deader [Boolean] stop for any dead player
      # @param group_deader [Boolean] stop for a dead group member
      # @param on_death [Symbol] :stop, :depart or :quit
      def initialize(stand_stance: 'defensive', pull: true, deader: false, group_deader: false, on_death: :stop) = super
    end

    # A player status that means on the ground (bigshot).
    DOWN = /sitting|^lying|prone/
    # A player status that Troubadour's Rally answers (bigshot).
    STUNNED = /webbed|sleeping|stunned|frozen|immobilized|held in place|horrified|staggered/i

    # The conditions, each read from the World without sending anything.
    module Predicates
      module_function

      # Players here on the ground and alive: with +pull+ any of
      # them while an aggressive creature is up, group members always.
      #
      # @param world [World]
      # @param policy [Policy]
      # @return [Array] the players to pull, in the room's order
      # @bigshot pull
      def to_pull(world, policy)
        players = Array(world.room.players).select { |p| p.status.to_s =~ DOWN && p.status.to_s !~ /dead/ }
        return players if policy.pull && Array(world.room.targets).any? { |t| t.type.to_s =~ /aggressive npc/ }

        nouns = world.group_nouns
        players.select { |p| nouns.include?(p.noun.to_s) }
      end

      # A dead player during the hunt, with the deader toggle; a dead group
      # member with group_deader. Both are the leader's checks: a
      # follower never stops for a deader. Unrelated corpses do not stop the
      # rest/prep/travel cycle; a group member's death still does.
      #
      # @param world [World]
      # @param policy [Policy]
      # @param follower [Boolean] we follow a leader
      # @param resting [Boolean] Rest holds the character
      # @return [Boolean]
      # @bigshot deader
      # @bigshot group_deader
      def deader?(world, policy, follower: false, resting: false)
        return false if follower

        dead = Array(world.room.players).select { |p| p.status.to_s =~ /dead/ }
        return true if !resting && policy.deader && dead.any?

        policy.group_deader && dead.any? { |p| world.group_nouns.include?(p.noun.to_s) }
      end

      # group_member_stunned?: us, or a group member by status.
      #
      # @param world [World]
      # @return [Boolean]
      # @bigshot group_member_stunned?
      def group_member_stunned?(world)
        me = world.me
        return true if me.webbed? || me.sleeping? || me.stunned? || (me.respond_to?(:frozen?) && me.frozen?)

        nouns = world.group_nouns
        Array(world.room.players).any? { |p| p.status.to_s =~ STUNNED && nouns.include?(p.noun.to_s) }
      end

      # In priority order: :dead, :trapped (an escape room), :deader (a dead
      # player to stop for), :prone (not standing, unless resting), :pull.
      #
      # @param world [World]
      # @param policy [Policy]
      # @param resting [Boolean] Rest holds the character
      # @param follower [Boolean] we follow a leader
      # @return [Symbol, nil] the first condition that holds, or nil
      def reason(world, policy, resting: false, follower: false)
        me = world.me
        return :dead if me.dead?
        return :trapped if Actions::Escape.kind_for(world.room.title)
        return :deader if deader?(world, policy, follower: follower, resting: resting)
        return :prone if !me.standing? && !resting && !me.muckled?
        return :pull if to_pull(world, policy).any?

        nil
      end
    end
  end

  module Actions
    # stand: drop to stand_stance, STAND until standing, restore the
    # stance we had. Never in the ooze. Bounded where bigshot loops.
    #
    # @bigshot stand
    class Stand < Base
      # STANDs sent before giving up with :still_down.
      ATTEMPTS = 3

      # @param world [World]
      # @param stance [#call, nil] (name) -> Boolean; default Lich's
      #   Stance.change
      # @param stand_stance [String, nil] the stance to stand in; nil
      #   leaves the stance alone
      # @param attempts [Integer] STANDs before giving up
      # @param timeout [Numeric] seconds to watch each STAND for standing
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, stance: nil, stand_stance: 'defensive', attempts: ATTEMPTS, timeout: 3, **opts)
        super(world, **opts)
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @stand_stance = stand_stance
        @attempts = attempts
        @timeout = timeout
      end

      # Dead, already standing, or in the Ooze refuses the stand.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :already_standing if me.standing?
        return :in_ooze if @world.room.title.to_s.include?('Ooze, Innards')

        :ok
      end

      # The stand stance when not already in it, STAND until standing or
      # the attempts run out, then the stance we had.
      #
      # @return [Actions::Result] the STAND that got us up, or failed
      #   with :still_down
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

      # Lich's Stance.at?, false when Lich cannot answer.
      #
      # @param name [String] a stance word or percentage
      # @return [Boolean]
      def stance_at?(name)
        ::Lich::Gemstone::Stance.at?(name) ? true : false
      rescue StandardError
        false
      end
    end

    # PULL a player to their feet, confirmed on the game's answer.
    #
    # @bigshot pull
    class Pull < Base
      # The game's answers to PULL, done or refused.
      ANSWERS = /^You (?:help|pull|grab|assist)|is already standing|doesn't need your help|^What were you referring to\?|^I could not find|^Roundtime/

      # @param world [World]
      # @param player [#noun] the player on the ground
      # @param timeout [Numeric] seconds to wait for an answer
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, player:, timeout: 3, **opts)
        super(world, **opts)
        @player = player
        @timeout = timeout
      end

      # Dead or muckled refuses the pull.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # PULL <noun>, matched against ANSWERS.
      #
      # @return [Actions::Result]
      def perform = send_and_match("pull #{@player.noun}", ANSWERS, timeout: @timeout)
    end

    # dead_man_switch: DEPART twice, DEPART CONFIRM twice. The
    # rest, ewaggle and the restart are the script's.
    #
    # @bigshot dead_man_switch
    class Depart < Base
      # Only a dead character departs.
      #
      # @return [Symbol] :ok, or :alive
      def preconditions = me.dead? ? :ok : :alive

      # This action runs dead.
      #
      # @return [Boolean] true
      def dead_ok? = true

      # The four sends, in order; the last one's answer is the Result.
      #
      # @return [Actions::Result] success with :departed, or the ladder's
      #   own failed Result
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
      # The condition found by the last wants_control?, or nil.
      #
      # @return [Symbol, nil] :dead, :trapped, :deader, :prone or :pull
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

      # The most urgent behavior there is.
      #
      # @return [Integer] 0
      def priority = 0

      # The way out of a muckle: this one runs while muckled.
      def runs_muckled? = true

      # Held by a snake or a root: kicks become punches (bigshot cmd 3318).
      #
      # @return [Boolean]
      # @bigshot cmd
      def rooted? = @rooted

      # Any survival condition holds; the reason is kept for the tick.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        @reason = EO::Engine::Survival::Predicates.reason(world, @policy, resting: @resting.call, follower: @follower)
        !@reason.nil?
      end

      # One action for the condition: the death policy, Escape, the
      # deader report, Stand, or Pull for the first downed player.
      #
      # @param world [World]
      # @return [Actions::Result, nil]
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

      # bigshot pauses itself and says ";u bigshot" to go on. The
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
