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
  module Flee
    # The profile's flee settings. +always_flee_from+ holds creature nouns
    # or names and player names; +boons_flee+ boon ability names;
    # +message+ a Regexp for the profile's flee_message, nil for none.
    Policy = Struct.new(
      :flee_count, :lone_targets_only, :always_flee_from,
      :clouds, :vines, :webs, :voids, :boons_flee, :message, :boundaries, :bandits,
      keyword_init: true
    ) do
      def count = (flee_count || 1).to_i
      def always = Array(always_flee_from)
      def boon_list = Array(boons_flee)

      def hazard_kinds
        kinds = []
        kinds << :cloud if clouds
        kinds << :vine if vines
        kinds << :web if webs
        kinds << :void if voids
        kinds
      end

      def boundary_ids = Array(boundaries).map(&:to_i)
    end

    module Predicates
      class << self
        # bigshot should_flee? (6866), in its order. +latched+ is the flee
        # message seen since the last bolt; +ambusher+ the hunt_monitor
        # latch; +just_entered+ makes lone_targets_only count as one.
        #
        # Bandit mode (policy.bandits): the ambusher hook is off (2760)
        # and nothing past always_flee_from flees (8540); a bandit fight
        # is an ambush by design.
        #
        # @return [Symbol, nil] :message, :hazard, :always_flee_from,
        #   :boon, :crowd
        def reason(room, targets_policy, policy, latched: false, ambusher: false, just_entered: false)
          return :message if latched
          return :ambusher if ambusher && !policy.bandits
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

  # The step chooser bigshot's bs_move (7539) is: every exit of the room
  # except boundaries and impassable gates, the ones not walked lately
  # first, else the least recently walked. Shared by Flee and Wander.
  module Wander
    class Walker
      attr_reader :visited

      def initialize(boundaries: [])
        @boundaries = Array(boundaries).map(&:to_i)
        @visited = [] # oldest first
      end

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
    # One step to a neighbouring room, confirmed by the room counter
    # changing (bigshot bs_move 7552: a String way is a move command with a
    # 5 s timeout, a proc way is called).
    class Move < Base
      def initialize(world, way:, timeout: 5, **opts)
        super(world, **opts)
        @way = way
        @timeout = timeout
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      def perform
        before = @world.room.count
        if @way.respond_to?(:call)
          @way.call
          deadline = clock_now + @timeout
          sleep 0.1 while @world.room.count == before && clock_now < deadline && !interrupted?
          return Result.new(status: @world.room.count == before ? :timeout : :success, reason: @world.room.count == before ? :state_unchanged : nil)
        end

        send_and_observe(@way.to_s, timeout: @timeout) { @world.room.count != before }
      end
    end

    # bigshot escape_rooms (7728), creature_escape (7791), temporal_escape
    # (7859): swallowed by a roa'ter, cut out with a dagger-class weapon;
    # swallowed by the Hinterwilds ooze, bludgeon the organ; dropped in a
    # Temporal Rift by a failed 930, walk random exits until out.
    class Escape < Base
      ROOMS = {
        worm: { title: 'The Belly of the Beast', command: 'attack wall' },
        ooze: { title: 'Ooze, Innards', command: 'kill organ' },
        rift: { title: 'Temporal Rift', command: nil }
      }.freeze

      # bigshot 2749-2760
      DAGGERS = /alfange|basilard|bodkin|cinquedea|dagger|dirk|knife|kozuka|ice pick|misericord|parazonium|pavade|poignard|pugio|scramasax|sgian achlais|spike|stiletto|tanto|sidearm-of-Onar/i
      BLUNTS = Regexp.union(
        /\b(?:whip|bull whip|cat o' nine tails|signal whip|single-tail whip|training whip)\b/,
        /\b(?:cudgel|aklys|baculus|club|jo stick|lisan|periperiu|shillelagh|tambara|truncheon|waihaka|war club)\b/,
        /\b(?:mace|bulawa|dhara|flanged mace|knee-breaker|massuelle|mattina|nifa otti|ox mace|pernat|quadrelle|ridgemace|studded mace)\b/,
        /\b(?:ball and chain|binnol|goupillon|mace and chain)\b/,
        /\b(?:morning star|spiked mace|holy water sprinkler|spikestar)\b/,
        /\b(?:cestus)\b/
      )
      WEAPONS = { worm: DAGGERS, ooze: BLUNTS }.freeze
      MAX_SWINGS = 40
      ANSWERED = /What were you referring to|^Roundtime|^You (?:swing|thrust|slash|attack|hack|jab|swipe)|^You can't|^You don't/

      # @return [Symbol, nil] which escape room we are in, by title
      def self.kind_for(title)
        ROOMS.find { |_, r| title.to_s.include?(r[:title]) }&.first
      end

      def initialize(world, kind: nil, **opts)
        super(world, **opts)
        @kind = kind
      end

      # Fixed once we are known to be trapped: the room title changing is
      # how we know we got out, so the kind must not follow it.
      def kind = @kind ||= self.class.kind_for(@world.room.title)

      def preconditions
        return :dead if me.dead?
        return :not_trapped if kind.nil?

        :ok
      end

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
        item if item && item.id && item.name.to_s =~ WEAPONS[kind] && item.type.to_s.include?('weapon')
      end

      # Every weapon we know of that fits, nearest first: hands, worn,
      # then containers. Wielded through Lich::Stash.wield (lich-5 #1579).
      def wield_weapon
        candidate = escape_candidates.find { |i| i.name.to_s =~ WEAPONS[kind] && i.type.to_s.include?('weapon') }
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
    # without waiting. One step per tick. Latches from the Watch:
    # :flee_message (the profile's line) and :ambusher, both cleared by
    # "You bolt" and by leaving the room.
    class Flee < Behavior
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
        @ambusher = false
        @just_entered = true
        @entered_room = nil
        Events.on(:flee_message) { @latched = true }
        Events.on(:ambusher) { |e| @ambusher = true unless @group_nouns.call.include?(e.data[:noun].to_s) }
        Events.on(:bolted) { @latched = false; @ambusher = false }
        Watch.on(policy.message, :flee_message) if policy.message
      end

      def priority = 10

      # Engage tells us when a fight has begun in this room, so the
      # lone_targets_only rule stops counting as one.
      def engaged! = @just_entered = false

      def wants_control?(world)
        note_room(world)
        @reason = EO::Engine::Flee::Predicates.reason(world.room, @targets_policy, @policy,
                                                      latched: @latched, ambusher: @ambusher, just_entered: @just_entered)
        !@reason.nil?
      end

      def tick(world)
        Events.emit(:fleeing, reason: @reason, room: world.room.id)
        step = @walker.next_step(world)
        return Actions::Result.new(status: :failed, reason: :no_exit) if step.nil?

        result = Actions::Move.new(world, way: step.last).call
        if result.success?
          @latched = false
          @ambusher = false
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

# The lines bigshot's hunt_monitor (2322) watches for the flee rules.
EO::Engine::Watch.on(%r{<a exist="\d+" noun="(?<noun>[a-zA-Z]*?)">[a-zA-Z]*?</a> leaps from hiding to attack!}i, :ambusher) { |m| { noun: m[:noun] } }
EO::Engine::Watch.on(/flies out of the shadows toward|A shadowy figure leaps from hiding to attack/i, :ambusher) { |_m| { noun: nil } }
EO::Engine::Watch.on(/^You bolt/i, :bolted)
