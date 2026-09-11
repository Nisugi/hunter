# frozen_string_literal: true

# ============================================================================
# flee (bigshot's should_flee?, the ambusher, escape rooms)
# ============================================================================

#
# EO::Engine::Flee - when to leave the room, and the leaving. In bigshot a
# flee is not the FLEE verb: should_flee? true breaks every command loop and
# bs_wander steps to the next room without waiting. Rules and bigshot line
# references in hunting-engine-plan.md, "Flee".
#
module EO::Engine
  # When to leave the room, and the leaving: bigshot's should_flee?, the
  # ambusher latch and the escape rooms.
  module Flee
    # The profile's flee settings. +always_flee_from+ holds creature nouns
    # or names and player names; +boons_flee+ boon ability names;
    # +message+ a Regexp for the profile's flee_message, nil for none.
    Policy = Struct.new(
      :flee_count, :lone_targets_only, :always_flee_from,
      :clouds, :vines, :webs, :voids, :boons_flee, :message, :boundaries, :bandits,
      keyword_init: true
    ) do
      # The crowd size that means flee, defaulting to 1.
      #
      # @return [Integer]
      def count = (flee_count || 1).to_i

      # always_flee_from as an Array, empty for none.
      #
      # @return [Array<String>]
      def always = Array(always_flee_from)

      # boons_flee as an Array, empty for none.
      #
      # @return [Array<String>]
      def boon_list = Array(boons_flee)

      # The hazard kinds the profile flees from, for Room#hazardous?.
      #
      # @return [Array<Symbol>] any of :cloud, :vine, :web, :void
      def hazard_kinds
        kinds = []
        kinds << :cloud if clouds
        kinds << :vine if vines
        kinds << :web if webs
        kinds << :void if voids
        kinds
      end

      # The boundary room ids as Integers.
      #
      # @return [Array<Integer>]
      def boundary_ids = Array(boundaries).map(&:to_i)
    end

    # The flee decision, pure: a room and the policies in, a reason out.
    module Predicates
      class << self
        # bigshot should_flee? (6866), in its order. +latched+ is the flee
        # message seen since the last bolt; +just_entered+ makes
        # lone_targets_only count as one.
        #
        # Bandit mode (policy.bandits): nothing past always_flee_from
        # flees (8540); a bandit fight is an ambush by design.
        #
        # @bigshot should_flee? 6866
        # @param room [World::Room] the room to judge
        # @param targets_policy [Targets::Policy] for the fightable count
        # @param policy [Flee::Policy]
        # @param latched [Boolean] the flee message was seen since the last bolt
        # @param just_entered [Boolean] no fight has begun in this room yet
        # @return [Symbol, nil] :message, :hazard, :always_flee_from,
        #   :boon, :crowd, or nil to stay
        def reason(room, targets_policy, policy, latched: false, just_entered: false)
          return :message if latched
          # The ambusher is deliberately not here. bigshot never leaves a
          # room over $ambusher_here: the latch breaks the attack loop
          # (attack_break 7750) and holds the leader (7824), and
          # reset_variables clears it on the next room (8836), which hands
          # the now-visible ambusher back as the target in the same room.
          # As a flee reason it made Flee (10) outrank Engage (50) and step
          # out of a fight bigshot finishes, and - since the latch cleared
          # only on a successful Move - a flee that could not happen (no
          # exit, muckled, a refused way) pinned the engine in permanent
          # flee.
          return :hazard if policy.hazard_kinds.any? && room.hazardous?(kinds: policy.hazard_kinds)
          return :always_flee_from if room.creatures.any? { |c| policy.always.include?(c.noun) || policy.always.include?(c.name) }
          return :always_flee_from if room.players.any? { |p| policy.always.include?(p.noun) || policy.always.include?(p.name) }
          return nil if policy.bandits
          return :boon if boon_flee?(room, targets_policy, policy)

          limit = just_entered && policy.lone_targets_only ? 1 : policy.count
          return :crowd if Targets.fightable_count(room.targets, targets_policy) > limit

          nil
        end

        # bigshot should_flee_from_boons? (6847): any boon creature in the
        # target list with a known ability on boons_flee.
        #
        # @bigshot should_flee_from_boons? 6847
        # @param room [World::Room]
        # @param targets_policy [Targets::Policy] its boon_abilities cache answers
        #   the creature's abilities
        # @param policy [Flee::Policy]
        # @return [Boolean]
        def boon_flee?(room, targets_policy, policy)
          return false if policy.boon_list.empty?

          room.targets.any? do |c|
            next false unless c.type.to_s.include?('boon')

            abilities = targets_policy.boon_abilities&.call(c)
            abilities && (Array(abilities) & policy.boon_list).any?
          end
        end
      end
    end
  end

  module Wander
    # The step chooser bigshot's bs_move (7539) is: every exit of the room
    # except boundaries and impassable gates, the ones not walked lately
    # first, else the least recently walked. Shared by Flee and Wander.
    #
    # @bigshot bs_move 7539
    class Walker
      # The rooms walked, oldest first.
      #
      # @return [Array<Integer>]
      attr_reader :visited

      # @param boundaries [Array<#to_i>] room ids never stepped into
      def initialize(boundaries: [])
        @boundaries = Array(boundaries).map(&:to_i)
        @visited = [] # oldest first
      end

      # Pick the next room: a fresh exit at random, else the least recently
      # walked one, and note it as walked.
      #
      # @param world [World] answers exits_from and the current room
      # @param random [Random] the fresh-exit picker, injectable for specs
      # @return [Array(Integer, Object), nil] [destination id, way] or nil when
      #   the room has no usable exit
      def next_step(world, random: Random.new)
        here = world.room.id
        return nil if here.nil?

        options = world.exits_from(here).reject { |dest, _| @boundaries.include?(dest.to_i) }
        return nil if options.empty?

        fresh = options.keys - @visited
        dest = fresh.empty? ? @visited.find { |r| options.key?(r) } : fresh[random.rand(fresh.size)]
        @visited.delete(dest)
        @visited << dest
        [dest, options[dest]]
      end
    end
  end

  module Actions
    # One step to a neighbouring room. A String way goes through Lich's
    # move, which confirms on the room counter and carries the refusal
    # ladder the engine has no lines for: a closed door retried as the
    # second door, an unhide when hidden entry is refused, climb falls
    # with a stand, swimming, drag failures, and the "can't go there"
    # family. A proc way (a StringProc on the map edge) is called and
    # confirmed on the counter here (bigshot bs_move 7552).
    #
    # @bigshot bs_move 7552
    class Move < Base
      # @param world [World]
      # @param way [String, #call] the exit text for Lich's move, or a proc way
      # @param timeout [Numeric] seconds to wait for the room counter to move
      # @param opts [Hash] passed through to Base
      def initialize(world, way:, timeout: 5, **opts)
        super(world, **opts)
        @way = way
        @timeout = timeout
      end

      # Dead or muckled refuses the step.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # Take the step: call a proc way and wait on the room counter, or
      # hand a String way to Lich's move and name what it said.
      #
      # @return [Actions::Result] success when the room changed; timeout with
      #   :state_unchanged for a proc way; failed with :not_allowed or :no_way
      def perform
        before = @world.room.count
        if @way.respond_to?(:call)
          @way.call
          deadline = clock_now + @timeout
          sleep 0.1 while @world.room.count == before && clock_now < deadline && !interrupted?
          return Result.new(status: @world.room.count == before ? :timeout : :success, reason: @world.room.count == before ? :state_unchanged : nil)
        end

        case game_move(@way.to_s)
        when true then Result.new(status: :success)
        when nil then Result.new(status: :failed, reason: :not_allowed) # the way is fine, not now
        else Result.new(status: :failed, reason: :no_way) # the way is bad; Lich's move said so
        end
      end

      # Lich's move: true moved, nil refused in a way that keeps the map
      # edge, false the way is bad or nothing answered within the timeout.
      #
      # @param way [String] the exit text
      # @return [Boolean, nil]
      def game_move(way) = move(way, @timeout)
    end

    # bigshot escape_rooms (7728), creature_escape (7791), temporal_escape
    # (7859): swallowed by a roa'ter, cut out with a dagger-class weapon;
    # swallowed by the Hinterwilds ooze, bludgeon the organ; dropped in a
    # Temporal Rift by a failed 930, walk random exits until out.
    #
    # @bigshot escape_rooms 7728
    # @bigshot creature_escape 7791
    # @bigshot temporal_escape 7859
    class Escape < Base
      # Each escape room by kind: the title fragment that names it and the
      # command that gets us out (nil for the rift, which is walked).
      ROOMS = {
        worm: { title: 'The Belly of the Beast', command: 'attack wall' },
        ooze: { title: 'Ooze, Innards', command: 'kill organ' },
        rift: { title: 'Temporal Rift', command: nil }
      }.freeze

      # The weapon each room wants, from Lich's Armaments catalogue: the
      # dagger group cuts out of the roa'ter, any blunt weapon bludgeons
      # the ooze organ. bigshot 2749-2760 listed the same names by hand,
      # a subset of the catalogue.
      #
      # MAX_SWINGS caps the swings at the wall or organ before giving up.
      MAX_SWINGS = 40
      # Every line that ends one swing's read: a swing, a roundtime, or a
      # refusal.
      ANSWERED = /What were you referring to|^Roundtime|^You (?:swing|thrust|slash|attack|hack|jab|swipe)|^You can't|^You don't/

      # @param title [String] the room title
      # @return [Symbol, nil] which escape room we are in, by title
      def self.kind_for(title)
        ROOMS.find { |_, r| title.to_s.include?(r[:title]) }&.first
      end

      # @param world [World]
      # @param kind [Symbol, nil] :worm, :ooze or :rift; nil reads it off the title
      # @param opts [Hash] passed through to Base
      def initialize(world, kind: nil, **opts)
        super(world, **opts)
        @kind = kind
      end

      # Fixed once we are known to be trapped: the room title changing is
      # how we know we got out, so the kind must not follow it.
      #
      # @return [Symbol, nil] :worm, :ooze, :rift, or nil when not trapped
      def kind = @kind ||= self.class.kind_for(@world.room.title)

      # Dead, or not in an escape room, refuses the escape.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :not_trapped if kind.nil?

        :ok
      end

      # Walk out of the rift, or wield a fitting weapon and swing at the
      # wall or organ until the title changes; with no weapon, stow and
      # wait to be spat out.
      #
      # @return [Actions::Result] success once out; failed with :still_trapped,
      #   :no_weapon, :interrupted or :dead
      def perform
        return escape_rift if kind == :rift

        weapon = weapon_in_hand || wield_weapon
        return wait_it_out(:no_weapon) if weapon.nil?

        swings = 0
        while trapped? && swings < MAX_SWINGS
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          result = send_and_match(ROOMS[kind][:command], ANSWERED, timeout: 5)
          return result if result.failed? && result.reason == :dead
          break if result.line.to_s =~ /What were you referring to/

          swings += 1
        end
        trapped? ? Result.new(status: :failed, reason: :still_trapped) : Result.new(status: :success)
      end

      private

      def trapped? = self.class.kind_for(@world.room.title) == kind

      def weapon_in_hand
        item = @world.hands.right
        item if item && item.id && fits?(item)
      end

      # A weapon of the kind this room wants: one of the catalogue's names
      # for the group, as a whole word in the item's name.
      def fits?(item)
        return false unless item.type.to_s.include?('weapon')

        name = item.name.to_s.downcase
        escape_weapon_names(kind).any? { |n| name =~ /\b#{Regexp.escape(n)}\b/ }
      end

      # Lich's WeaponStats: the dagger entry's names for the worm, every
      # blunt weapon's names for the ooze.
      def escape_weapon_names(kind)
        stats = ::Lich::Gemstone::Armaments::WeaponStats
        names = case kind
                when :worm then Array(stats.find('dagger', :edged)&.fetch(:all_names, nil))
                when :ooze then Array(stats.list(:blunt)).flat_map { |w| Array(w[:all_names]) }
                else []
                end
        names.map(&:downcase).reject { |n| %w[name alt].include?(n) }
      rescue StandardError
        []
      end

      # Every weapon we know of that fits, nearest first: hands, worn,
      # then containers. Wielded through Lich::Stash.wield (lich-5 #1579).
      def wield_weapon
        candidate = escape_candidates.find { |i| fits?(i) }
        return nil if candidate.nil?

        wield(candidate)
        weapon_in_hand
      rescue StandardError
        nil
      end

      # The seam: outside Lich there is no inventory.
      def escape_candidates
        return [] unless defined?(::GameObj)

        [::GameObj.left_hand, *Array(::GameObj.inv), *Array(::GameObj.containers.values).flatten].compact
      end

      def wield(item) = ::Lich::Stash.wield(item, hand: :right)

      # bigshot: no weapon, stow and wait for the creature to spit us out.
      def wait_it_out(reason)
        send_through_ladder('stow all')
        deadline = clock_now + 120
        sleep 1 while trapped? && clock_now < deadline && !interrupted?
        trapped? ? Result.new(status: :failed, reason: reason) : Result.new(status: :success, reason: reason)
      end

      def escape_rift
        20.times do
          return Result.new(status: :success) unless trapped?
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          exits = @world.room.exits
          break if exits.empty?

          Move.new(@world, way: exits.sample, interrupt: @interrupt).call
        end
        trapped? ? Result.new(status: :failed, reason: :still_trapped) : Result.new(status: :success)
      end
    end
  end

  module Behaviors
    # bigshot's flee: should_flee? breaks the fight and bs_wander steps out
    # without waiting. One step per tick. The latch from the Watch is
    # :flee_message (the profile's line), cleared by "You bolt" and by
    # leaving the room.
    #
    # @bigshot should_flee? 6866
    class Flee < Behavior
      # Why the last wants_control? said yes.
      #
      # @return [Symbol, nil] a Flee::Predicates.reason, or nil
      attr_reader :reason

      # @param policy [Flee::Policy]
      # @param targets_policy [Targets::Policy]
      # @param walker [Wander::Walker] shared with Wander
      # @param group_nouns [#call] -> Array<String>, the group's nouns (an
      #   ambusher who is a group member is not an ambusher)
      def initialize(policy:, targets_policy:, walker: nil, group_nouns: nil)
        super()
        @policy = policy
        @targets_policy = targets_policy
        @walker = walker || EO::Engine::Wander::Walker.new(boundaries: policy.boundary_ids)
        @group_nouns = group_nouns || -> { [] }
        @latched = false
        @just_entered = true
        @entered_room = nil
        Events.on(:flee_message) { @latched = true }
        Events.on(:bolted) { @latched = false }
        Watch.on(policy.message, :flee_message) if policy.message
      end

      # Second only to Survival.
      #
      # @return [Integer] 10
      def priority = 10

      # Engage tells us when a fight has begun in this room, so the
      # lone_targets_only rule stops counting as one.
      #
      # @return [void]
      def engaged! = @just_entered = false

      # Ask the predicate, keeping its reason for the tick.
      #
      # @param world [World]
      # @return [Boolean] true when there is a reason to leave
      def wants_control?(world)
        note_room(world)
        @reason = EO::Engine::Flee::Predicates.reason(world.room, @targets_policy, @policy,
                                                      latched: @latched, just_entered: @just_entered)
        !@reason.nil?
      end

      # One step out through the walker; a successful step clears the
      # latches.
      #
      # @param world [World]
      # @return [Actions::Result] the Move's result, or failed with :no_exit
      def tick(world)
        Events.emit(:fleeing, reason: @reason, room: world.room.id)
        step = @walker.next_step(world)
        return Actions::Result.new(status: :failed, reason: :no_exit) if step.nil?

        result = Actions::Move.new(world, way: step.last).call
        if result.success?
          @latched = false
          @just_entered = true
        end
        result
      end

      private

      def note_room(world)
        id = world.room.id
        return if id == @entered_room

        @entered_room = id
        @just_entered = true
      end
    end
  end
end
