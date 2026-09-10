# frozen_string_literal: true

# ============================================================================
# wander (bigshot's bs_wander, the hunting area, the claim, hide)
# ============================================================================

#
# bigshot's bs_wander (7562) is the loop between fights: on arriving, give
# the room wander_wait seconds to show a creature if the room is ours, and
# hand any valid one to the attack loop; otherwise drop to the wander
# stance, hide when sneaking, and step to the next room by bs_move, or go2
# the hunting room when outside the area (BSAreaRooms, 620). The engine's
# Wander is that as a behavior at the bottom of the priority list: Engage
# outranks it while there is something to fight, so wants_control? is
# simply "there is nothing to fight here", and tick is one wait, one
# stance, one hide, or one step. Rules and bigshot line references in
# hunting-engine-plan.md, "Wander".
#
module EO::Engine
  module Wander
    # hunting_room / hunting_boundaries / wander_wait / sneaky_sneaky /
    # ignore_disks / wander_stance from the profile (2861-2897).
    Policy = Struct.new(:hunting_room, :boundaries, :wander_wait, :sneaky, :ignore_disks, :wander_stance, keyword_init: true) do
      def initialize(hunting_room: nil, boundaries: [], wander_wait: 0.3, sneaky: false, ignore_disks: false, wander_stance: nil) = super

      def boundary_ids = Array(boundaries).map(&:to_i)
    end

    # The hunting area, bigshot's BSAreaRooms (620): every room reachable
    # from the hunting room through passable exits without crossing a
    # boundary. More than CAP rooms means a boundary is missing; bigshot
    # prints the first location changes and exits, the engine reports
    # too_big? and lets the script decide.
    class Area
      CAP = 200

      attr_reader :start, :rooms, :location_changes

      def initialize(start:, boundaries: [], cap: CAP)
        @start = start.to_i
        @boundaries = Array(boundaries).map(&:to_i)
        @cap = cap
        @rooms = nil
        @too_big = false
        @location_changes = []
      end

      def build(world)
        rooms = [@start]
        frontier = [@start]
        seen = { @start => true }
        last_location = location_of(world, @start)
        until frontier.empty?
          next_frontier = []
          frontier.each do |id|
            world.exits_from(id).each_key do |dest|
              next if @boundaries.include?(dest) || seen[dest]

              seen[dest] = true
              next_frontier << dest
              loc = location_of(world, dest)
              if loc && loc != last_location
                last_location = loc
                @location_changes << { id: dest, location: loc } if @location_changes.size < 3
              end
            end
          end
          rooms.concat(next_frontier)
          frontier = next_frontier
          if rooms.size >= @cap
            @too_big = true
            break
          end
        end
        @rooms = rooms
        self
      end

      def built? = !@rooms.nil?

      def too_big? = @too_big

      def include?(id) = built? && @rooms.include?(id.to_i)

      private

      def location_of(world, id)
        world.respond_to?(:room_location) ? world.room_location(id) : nil
      end
    end

    module Predicates
      module_function

      # bigshot bigclaim? (5921): the room is ours when Claim says so and
      # every disk here is the group's, unless the profile ignores disks.
      # Quick mode and a follower always say yes; both are the script's.
      def claim_ours?(world, policy)
        return false unless world.claim_mine?

        policy.ignore_disks || world.foreign_disks.empty?
      end

      # Something to fight here: the room is ours and a wanted, fightable
      # creature is on the target list (bs_wander 7575-7577).
      def fight_here?(world, targets_policy, policy)
        claim_ours?(world, policy) && Targets.candidates(world.room.targets, targets_policy).any?
      end
    end
  end

  module Actions
    # HIDE until hidden, a few tries (bigshot cmd_hide 5121: up to
    # +attempts+ sends, stopping on a flee). The stance drop bigshot does
    # first is the caller's.
    class Hide < Base
      ATTEMPTS = 3

      def initialize(world, attempts: ATTEMPTS, timeout: 2, **opts)
        super(world, **opts)
        @attempts = attempts
        @timeout = timeout
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?
        return :already_hidden if me.hidden?

        :ok
      end

      def perform
        result = nil
        @attempts.times do
          result = send_and_observe('hide', timeout: @timeout) { me.hidden? }
          return result if result.success? || result.status == :failed
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
        end
        Result.new(status: :timeout, reason: :not_hidden)
      end
    end
  end

  module Behaviors
    # One wait, stance, hide or step per tick between fights.
    class Wander < Behavior
      attr_reader :arrived_at

      # @param policy [Wander::Policy]
      # @param targets_policy [Targets::Policy]
      # @param walker [Wander::Walker] shared with Flee
      # @param area [Wander::Area, nil] built by the script; nil never sends home
      # @param travel [#call] (room) -> Trip or Boolean; default a Travel trip
      # @param stance [#call] (name) -> Boolean; default Lich::Gemstone::Stance.change
      # @param tracking [Tracking::Policy] bandit mode and the Ranger's quarry
      def initialize(policy:, targets_policy:, walker: nil, area: nil, travel: nil, stance: nil, tracking: nil, clock: Time)
        super()
        @policy = policy
        @targets_policy = targets_policy
        @walker = walker || EO::Engine::Wander::Walker.new(boundaries: policy.boundary_ids)
        @area = area
        @travel = travel || EO::Engine::Travel.default
        @trip = nil
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @tracking = tracking || EO::Engine::Tracking::Policy.new
        @clock = clock
        @entered_room = nil
        @arrived_at = nil
        @stanced = false
        @tracked = false
      end

      def priority = 60

      # The engine's stop: end a trip home in flight.
      def cancel! = EO::Engine::Travel.cancel(self)

      # Another behavior took control: hold the trip home until it is ours again.
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      def wants_control?(world)
        note_room(world)
        !EO::Engine::Wander::Predicates.fight_here?(world, @targets_policy, @policy)
      end

      def tick(world)
        note_room(world)
        # bigshot sleeps wander_wait after the first look and looks again;
        # here Engage takes over the moment a creature shows, so the wait
        # is simply time in the room before leaving it. Only in a room
        # that is ours: a claimed room is left at once (7575).
        return nil if ours?(world) && @clock.now - @arrived_at < @policy.wander_wait.to_f

        unless @stanced
          @stanced = true
          @stance.call(@policy.wander_stance) if @policy.wander_stance
        end

        if @policy.sneaky && !world.me.hidden?
          hide = Actions::Hide.new(world).call
          return hide if hide.status == :failed
        end

        # bs_wander 9427: a Ranger tracks the quarry before stepping; a
        # trail or a hidden quarry in our room holds us here.
        if @tracking.tracking? && !@tracked && !@trip
          @tracked = true
          tracked = track(world)
          return tracked if tracked
        end

        if @trip || (@area&.built? && !@area.include?(world.room.id))
          Events.emit(:out_of_bounds, room: world.room.id, hunting_room: @policy.hunting_room) if @trip.nil?
          case EO::Engine::Travel.step(self, @travel, @policy.hunting_room, world)
          when :underway then return nil
          when :arrived then return Actions::Result.new(status: :success, reason: :returned_home)
          else return Actions::Result.new(status: :failed, reason: :could_not_reach)
          end
        end

        step = @walker.next_step(world)
        return Actions::Result.new(status: :failed, reason: :no_exit) if step.nil?

        Actions::Move.new(world, way: step.last).call
      end

      private

      def ours?(world) = EO::Engine::Wander::Predicates.claim_ours?(world, @policy)

      # ranger_track 9500-9512: a Result to return when the track holds us
      # in place (uncovering when nothing hostile shows), nil to move on.
      def track(world)
        result = Actions::Track.new(world, creature: @tracking.creature_name).call
        case result.reason
        when :trail
          Actions::Uncover.new(world).call if world.room.targets.empty?
          Events.emit(:tracked, creature: @tracking.creature_name, outcome: :trail, room: world.room.id)
          Actions::Result.new(status: :success, reason: :tracked)
        when :here
          return nil unless ours?(world)

          Actions::Uncover.new(world).call if world.room.targets.empty?
          Events.emit(:tracked, creature: @tracking.creature_name, outcome: :here, room: world.room.id)
          Actions::Result.new(status: :success, reason: :tracked)
        end
      end

      def note_room(world)
        id = world.room.id
        return if id == @entered_room

        @entered_room = id
        @arrived_at = @clock.now
        @stanced = false
        @tracked = false
      end
    end
  end
end
