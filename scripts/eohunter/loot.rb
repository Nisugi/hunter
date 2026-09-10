# frozen_string_literal: true

# ============================================================================
# loot (bigshot's need_to_loot?, loot, looting_watch, the final loot)
# ============================================================================

#
# bigshot loots after every command set (attack_break -> need_to_loot?
# 6578), before a rest for some reasons (should_rest? 7294) and before
# leaving a room when final_loot is on (bs_wander 7618). The loot itself
# (6620) is the loot script when the profile names one, else LOOT #id and
# LOOT ROOM per corpse, with the fried bookkeeping (boost, overkill) per
# corpse before it. The engine's Loot is a behavior at priority 30, above
# Maintain and Engage: a corpse in a room that is ours is looted before
# the next swing unless delay_loot says to keep fighting. Rules and
# bigshot line references in hunting-engine-plan.md, "Loot".
#
module EO::Engine
  # When to loot, and the looting: bigshot's need_to_loot?, loot and
  # looting_watch.
  module Loot
    # loot_script / delay_loot / loot_stance / final_loot / box_in_hand
    # from the profile (2876-2956).
    Policy = Struct.new(:script, :delay, :stance, :final, :box_in_hand, :delay_seconds, keyword_init: true) do
      def initialize(script: nil, delay: false, stance: false, final: false, box_in_hand: false, delay_seconds: 15) = super
    end

    # Rooms bigshot never loots in (need_to_loot? 6581).
    NO_LOOT_ROOMS = ['Duskruin Arena, Dueling Sands', 'The Belly of the Beast', 'Ooze, Innards', 'Temporal Rift'].freeze

    # The loot decision, pure: the world and the policies in, a reason out.
    module Predicates
      module_function

      # Dead creatures here that are not escorts (6587).
      #
      # @bigshot need_to_loot? 6587
      # @param room [World::Room]
      # @return [Array<#id>] the corpses
      def deaders(room)
        Array(room.creatures).select { |c| c.status.to_s == 'dead' && c.type.to_s !~ /escort/i }
      end

      # The room title names one of NO_LOOT_ROOMS.
      #
      # @param room [World::Room]
      # @return [Boolean]
      def no_loot_room?(room)
        title = room.title.to_s
        NO_LOOT_ROOMS.any? { |t| title.include?(t) }
      end

      # need_to_loot? (6578) minus the parts other behaviors own (a flee
      # or an ambusher outranks Loot; followers are M3):
      # - the claim, without the disk check
      # - not in an arena or an escape room
      # - a corpse here, or nothing left to fight and loot on the floor
      # - with delay_loot and something still to fight, only every
      #   delay_seconds unless this is the final loot
      #
      # @bigshot need_to_loot? 6578
      # @param world [World]
      # @param targets_policy [Targets::Policy] for the fight check
      # @param policy [Loot::Policy]
      # @param final [Boolean] the final loot: no delay, and the floor counts
      # @param last_at [Time, nil] when the delayed loot last ran
      # @param now [Time] the clock, for the delay
      # @param looted [Array<String>] corpse ids already looted here
      # @return [Symbol, nil] :corpses, :floor, or nil
      def reason(world, targets_policy, policy, final: false, last_at: nil, now: Time.now, looted: [])
        return nil unless world.claim_mine?
        return nil if no_loot_room?(world.room)

        corpses = deaders(world.room).reject { |c| looted.include?(c.id.to_s) }
        fighting = Targets.candidates(world.room.targets, targets_policy).any?
        if corpses.any?
          return nil if policy.delay && fighting && !final && last_at && now - last_at < policy.delay_seconds

          :corpses
        elsif !fighting && Array(world.room.loot).any? && final
          :floor
        end
      end
    end
  end

  module Actions
    # LOOT #id or LOOT ROOM, confirmed on the game's answer (bigshot sends
    # both bare, 6648).
    #
    # @bigshot loot 6648
    class Loot < Base
      # Every line that answers a LOOT: found something, found nothing, a
      # bad referent, a roundtime, or already searched.
      ANSWERS = Regexp.union(
        /^You search|^You find|^You gather|^You rummage|^You discover/,
        /^There (?:is|was) nothing|^There is no loot\.|^Nothing to loot|nothing (?:of value|else) /i,
        /^What were you referring to\?|^I could not find what you were referring to\./,
        /^Roundtime/, /already been searched/i, /has nothing/i
      )

      # @param world [World]
      # @param target [#id, nil] the corpse; nil loots the room
      # @param timeout [Numeric] seconds to wait for the game's answer
      # @param opts [Hash] passed through to Base
      def initialize(world, target: nil, timeout: 3, **opts)
        super(world, **opts)
        @target = target
        @timeout = timeout
      end

      # Dead or muckled refuses the loot.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # The text sent: "loot #id" for a corpse, else "loot room".
      #
      # @return [String]
      def command = @target ? "loot ##{@target.id}" : 'loot room'

      # Send the command and read for any ANSWERS line.
      #
      # @return [Actions::Result] the send_and_match result
      def perform = send_and_match(command, ANSWERS, timeout: @timeout)
    end
  end

  module Behaviors
    # One corpse, one script start, or one wait per tick.
    #
    # @bigshot need_to_loot? 6578
    class Loot < Behavior
      # When a corpse was last looted, for delay_loot.
      #
      # @return [Time, nil]
      attr_reader :last_at

      # @param policy [Loot::Policy]
      # @param targets_policy [Targets::Policy]
      # @param rest_policy [Rest::Policy] for the fried bookkeeping
      # @param counters [Rest::Counters]
      # @param scripts [#start, #running?, #kill, #paused?] default Lich's Script
      # @param stance [#call] (name) -> Boolean
      # @param group [Group::Leader, nil] the leader's: the looter choice and the wait for it
      # @param follower [Boolean] loots only when assigned by a loot order
      # @param clock [#now] the time source, injectable for specs
      def initialize(policy:, targets_policy:, rest_policy: EO::Engine::Rest::Policy.new, counters: EO::Engine::Rest::Counters.new,
                     scripts: nil, stance: nil, group: nil, follower: false, clock: Time)
        super()
        @policy = policy
        @targets_policy = targets_policy
        @rest_policy = rest_policy
        @counters = counters
        @scripts = scripts || EO::Engine::Behaviors::Rest::LichScripts
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @group = group
        @follower = follower
        @assigned = false
        @clock = clock
        @looted = []
        @floor_looted_signature = nil
        @entered_room = nil
        @last_at = nil
        @final = false
        @script_running = false
        @script_corpses = []
        @stanced = false
        Events.on(:entered_room) { @looted.clear }
      end

      # Above Maintain and Engage, below Survival and Flee.
      #
      # @return [Integer] 30
      def priority = 30

      # Rest (before leaving for a rest reason that is not wounds) and
      # Wander (final_loot before leaving a room) ask for the final loot:
      # no delay, and the floor is looted too.
      #
      # @return [void]
      def final! = @final = true

      # The leader's loot order named us (tail 10165): loot this room.
      #
      # @bigshot tail 10165
      # @return [void]
      def assign! = @assigned = true

      # What the follower reports (looting_inactive? 9261).
      #
      # @bigshot looting_inactive? 9261
      # @return [Boolean] assigned, or the loot script still running
      def looting? = @assigned || @script_running

      # A loot script in flight, or the predicate's reason, minus a floor
      # already looted as it stands now; the group rules first.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        note_room(world)
        @floor_looted_signature = nil if Array(world.room.loot).empty?
        return true if @script_running
        # need_to_loot? 7821-7825: the leader only, and not while a
        # follower is still looting; a follower only when told to.
        return false if @follower && !@assigned
        return false if @group && !@group.solo? && !@group.looting_done?

        @reason = EO::Engine::Loot::Predicates.reason(world, @targets_policy, @policy, final: @final || @policy.final || @assigned,
                                                                                       last_at: @last_at, now: @clock.now, looted: @looted)
        @reason = nil if @reason == :floor && floor_signature(world) == @floor_looted_signature
        @assigned = false if @follower && @reason.nil?
        !@reason.nil?
      end

      # Watch a running script, else the stance drop, then one corpse:
      # handed to the group's looter, started as the loot script, or
      # LOOT #id then LOOT ROOM; with no corpse left, the floor.
      #
      # @param world [World]
      # @return [Actions::Result, nil] nil while the script runs or when there
      #   is nothing to do; else the loot's result, or success with
      #   :loot_assigned, :script_started or :script_finished
      def tick(world)
        return watch_script(world) if @script_running

        # loot_stance (6626): drop to defensive with creatures still up
        if @policy.stance && !@stanced && Targets.fightable_count(world.room.targets, @targets_policy).positive?
          @stanced = true
          @stance.call('defensive')
        end

        corpse = EO::Engine::Loot::Predicates.deaders(world.room).find { |c| !@looted.include?(c.id.to_s) }
        return loot_floor(world) if corpse.nil?

        # need_to_loot? 7845-7856: the looter; a follower gets the order
        # and this room's corpses are theirs.
        if @group && !@group.solo?
          looter = @group.looter(me_left: @rest_policy.encumbered_pct - world.me.encumbrance_pct.to_i)
          if looter != @group.name
            EO::Engine::Loot::Predicates.deaders(world.room).each { |c| @looted << c.id.to_s }
            @group.order(:prep_rest, room: world.room.id)
            @group.order(:loot, looter, room: world.room.id)
            Events.emit(:loot_assigned, looter: looter, room: world.room.id)
            return Actions::Result.new(status: :success, reason: :loot_assigned)
          end
        end

        bookkeep(world)
        @last_at = @clock.now
        if @policy.script
          start_script(world)
        else
          @looted << corpse.id.to_s
          result = Actions::Loot.new(world, target: corpse).call
          loot_room(world) if result.success?
          result
        end
      end

      private

      # use_lte_boost then add_overkill per corpse (6642): the boost when
      # fried with boosts left, else one overkill when fried and spent.
      # The leader's kill counts for the followers too (add_overkill 9060).
      def bookkeep(world)
        @group.order(:follower_overkill, room: world.room.id) if @group && !@group.solo?
        boost = Actions::LteBoost.new(world, counters: @counters, policy: @rest_policy).call
        return if boost.success?

        if EO::Engine::Rest::Predicates.fried?(world.me, @rest_policy) && EO::Engine::Rest::Predicates.lte_boosts_spent?(@counters, @rest_policy)
          @counters.overkill += 1
          Events.emit(:overkill, count: @counters.overkill, max: @rest_policy.overkill_max)
        end
      end

      def loot_floor(world)
        @final = false
        @assigned = false
        @stanced = false
        return nil unless @reason == :floor

        @reason = nil
        if @policy.script
          start_script(world)
        else
          loot_room(world)
        end
      end

      def loot_room(world)
        result = Actions::Loot.new(world, target: nil).call
        @floor_looted_signature = floor_signature(world) if result.success?
        result
      end

      def floor_signature(world)
        items = Array(world.room.loot)
        return nil if items.empty?

        items.map do |item|
          %i[id name noun type].map { |field| item.respond_to?(field) ? item.public_send(field).to_s : '' }.join("\0")
        end.sort.freeze
      end

      # run_script (5835): a running or paused copy is killed first; the
      # script loots the whole room, so every corpse here is its.
      def start_script(world)
        name = @policy.script.to_s.split(/\s+/).first
        args = @policy.script.to_s.split(/\s+/, 2)[1]
        if @scripts.running?(name)
          @scripts.kill(name)
          20.times { break unless @scripts.running?(name); sleep 0.1 }
        end
        @script_corpses = EO::Engine::Loot::Predicates.deaders(world.room).map { |c| c.id.to_s }
        @scripts.start(name, args)
        @script_running = true
        Events.emit(:loot_script_started, script: name)
        Actions::Result.new(status: :success, reason: :script_started)
      end

      # looting_watch (6657): wait for the script; a pause with a box in
      # hand means it could not store the box, which is a forced rest.
      def watch_script(world)
        name = @policy.script.to_s.split(/\s+/).first
        if @scripts.running?(name) && !@scripts.paused?(name)
          return nil
        end

        @script_running = false
        @looted.concat(@script_corpses)
        @script_corpses = []
        if @scripts.paused?(name)
          @scripts.kill(name)
          box = [world.hands.right, world.hands.left].find { |h| h.type.to_s =~ /box/ }
          if box
            Events.emit(:loot_stuck, reason: 'Box in hand, couldn\'t store')
            return Actions::Result.new(status: :failed, reason: :box_in_hand)
          end
        end
        Actions::Result.new(status: :success, reason: :script_finished)
      end

      def note_room(world)
        id = world.room.id
        return if id == @entered_room

        @entered_room = id
        @looted.clear
        @floor_looted_signature = nil
        @stanced = false
        @final = false
      end
    end
  end
end
