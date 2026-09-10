# frozen_string_literal: true

# ============================================================================
# group (bigshot's head/tail: Bigshot::Group over DRb, Event, the follower
#        loop, and every follower wait in the leader's hunt and rest)
# ============================================================================

#
# bigshot's group is a Bigshot::Group object the leader serves over DRb
# (9882); each follower registers its own Bigshot instance in it (10023)
# and the leader calls those instances directly for every question
# (ready_to_hunt?, looting_inactive?, rt? ...) and pushes Events onto
# their stacks (add_event 1061), which the follower loop (10060) works
# through one at a time. The engine keeps the shape and turns the calls
# around: the leader serves a Hub, followers push a Report into it every
# tick and pull their Orders from it, so the leader never makes a remote
# call and a follower that stops reporting is seen as lost instead of
# raising into the leader's loop. A follower's every call to the Hub is
# bounded, and a Hub that stops answering (the leader's Lich is gone) is
# a lost leader. Every order and every ack carries the hunt id.
#
#   Hub      the protocol object: roster, readiness, orders, reports, acks
#   Leader   the leader's view of the Hub: the group waits bigshot makes
#   Member   the follower's link to a Hub, remote calls bounded
#   Orders   the follower's Rest: the leader's orders, one step per tick
#   Assist   the follower's Engage: the leader's target first
#   Follow   the follower's Wander: back to the leader, join the group
#   Muster   the leader's holds between fights
#
# Rules and bigshot line references in hunting-engine-plan.md, "Group".
#
module EO::Engine
  module Group
    # The MA Grouping settings from the profile (3549-3563).
    Policy = Struct.new(:independent_travel, :independent_return, :group_deader, :looter, :quiet_followers,
                        :never_loot, :random_loot, :fried_trigger, keyword_init: true) do
      def initialize(independent_travel: false, independent_return: false, group_deader: false, looter: nil,
                     quiet_followers: true, never_loot: [], random_loot: false, fried_trigger: ['any']) = super

      def never_loot_list = Array(never_loot).map(&:to_s)

      # Whether the currently fried members satisfy the configured group
      # trigger. The profile accepts "any", "all", or one or more names.
      def fried_rest?(fried_names, active_names:)
        trigger = Array(fried_trigger).flat_map { |value| value.to_s.split(',') }
                                      .map { |value| value.strip.downcase }
                                      .reject(&:empty?)
        fried = Array(fried_names).map { |name| name.to_s.downcase }
        active = Array(active_names).map { |name| name.to_s.downcase }

        return fried.any? if trigger.empty? || trigger.include?('any')
        return (active - fried).empty? if trigger.include?('all')

        !(trigger & fried).empty?
      end
    end

    # bigshot's Event types (766), by their engine names.
    ORDERS = %i[
      attack follow_now prepare_move hunting_prep hunting_scripts_start hunting_scripts_stop cast_signs check_sneaky
      go2_rally go2_hunting_room prep_rest leave_group fog_return go2_waypoints go2_resting_room
      resting_prep resting_scripts_start loot unhide follower_overkill hunt_over command
    ].freeze

    # One instruction from the leader (Event 763): raised in a room at a
    # time, for one hunt. An attack order from another room or older than
    # 15 s is stale (793).
    STALE_AFTER = 15

    Order = Struct.new(:type, :hunt_id, :room, :at, :payload, keyword_init: true) do
      def stale?(room_now, now = Time.now)
        room != room_now || (now.to_f - at.to_f) > Group::STALE_AFTER
      end
    end

    # What a follower tells the leader every tick: the answers bigshot's
    # leader asks each member for (ready_to_rest? 8977, ready_to_hunt?
    # 8917, rt? 8732, looting_inactive? 9261, rest_prep_done? 8737,
    # encumbrance? 8768, sneaky_hunt? 8763, player_hidden? 8758).
    Report = Struct.new(:name, :room, :rt, :hidden, :sneaky, :looting, :rest_prep_done, :rest_reason,
                        :not_hunting_reason, :encumbrance_left, :wounded, :bounty, :at, keyword_init: true)

    # A member's bounty state for the report (the split plan's 3.1), from
    # Lich's Bounty task: :none, :hunting, :complete or :failed.
    def self.bounty_state(world)
      task = world.bounty_task
      return :none if task.nil? || task.none?
      return :failed if task.type == :failed
      return :complete if task.done?

      :hunting
    end

    # The Report for this tick, from the follower's own policies.
    #
    # @param bounty [Symbol, nil] :none, :hunting, :complete or :failed
    def self.report(world, name:, rest_policy:, counters:, sneaky: false, looting: false, rest_prep_done: false, bounty: nil, now: Time.now)
      me = world.me
      Report.new(
        name: name, room: world.room.id, rt: me.in_rt? || me.in_cast_rt?, hidden: me.hidden?, sneaky: sneaky,
        looting: looting, rest_prep_done: rest_prep_done,
        rest_reason: Rest::Predicates.rest_reason(me, rest_policy, counters, looting: looting),
        not_hunting_reason: Rest::Predicates.not_hunting_reason(me, rest_policy),
        encumbrance_left: rest_policy.encumbered_pct - me.encumbrance_pct.to_i,
        wounded: rest_policy.wounded ? (rest_policy.wounded.call ? true : false) : false,
        bounty: bounty, at: now
      )
    end

    # The protocol object. Served over DRb by the leader; every method is
    # safe to call from any thread. No game state: pure Ruby.
    class Hub
      include ::DRbUndumped if defined?(::DRbUndumped)

      REPORT_STALE = 10    # a follower silent this long is offline
      HEARTBEAT_STALE = 15 # a leader silent this long is lost
      PULSE = 3            # the liveness pulse, well inside both

      attr_reader :hunt_id, :leader_name, :expected, :rooms, :last_exit

      def initialize(clock: Time)
        @clock = clock
        @mutex = Mutex.new
        @hunt_id = nil
        @leader_name = nil
        @expected = []
        @rooms = {}
        @members = {}
        @queues = {}
        @reports = {}
        @acks = {}
        @active = false
        @leader_state = {}
        @heartbeat = nil
        @finished = nil
        @last_exit = nil
      end

      # --- the leader --------------------------------------------------------

      # A new hunt: a fresh id, the roster it expects (a count, or the
      # names), the leader's rooms for the followers' own trips.
      #
      # @param expected [Integer, Array<String>]
      # @param rooms [Hash] :rally, :hunting, :waypoints, :resting
      def open_hunt(leader:, expected:, rooms: {})
        @mutex.synchronize do
          @hunt_id = format('%08x', rand(2**32))
          @leader_name = leader.to_s
          @expected = expected.is_a?(Integer) ? expected : Array(expected).map(&:to_s)
          @rooms = rooms
          @members = {}
          @queues = {}
          @reports = {}
          @acks = {}
          @active = false
          @leader_state = {}
          @heartbeat = @clock.now
          @finished = nil
          @last_exit = nil
          @hunt_id
        end
      end

      def open? = !@hunt_id.nil?

      def members = @mutex.synchronize { @members.keys }

      # bigshot's rally wait (9903): every expected follower has registered.
      def ready?
        @mutex.synchronize do
          @expected.is_a?(Integer) ? @members.size >= @expected : (@expected - @members.keys).empty?
        end
      end

      def missing
        @mutex.synchronize do
          @expected.is_a?(Integer) ? ["#{[@expected - @members.size, 0].max} more"] : @expected - @members.keys
        end
      end

      def activate! = @mutex.synchronize { @active = true }
      def active? = @active

      # The leader's state, every tick: room, target, phase, looter.
      def heartbeat!(state = {})
        @mutex.synchronize do
          @leader_state = state
          @heartbeat = @clock.now
        end
        true
      end

      def leader_state = @mutex.synchronize { @leader_state.dup }

      def leader_alive?(now = @clock.now)
        @mutex.synchronize { @finished.nil? && !@heartbeat.nil? && (now.to_f - @heartbeat.to_f) < HEARTBEAT_STALE }
      end

      def leader_finished!(reason)
        @mutex.synchronize { @finished = reason }
        reason
      end

      def finished_reason = @finished

      # An order to every registered follower (add_event 1061).
      def broadcast(type, payload = nil, room: nil)
        order = make_order(type, payload, room)
        @mutex.synchronize { @queues.each_value { |q| q << order } }
        order
      end

      # An order to one follower.
      def order(name, type, payload = nil, room: nil)
        order = make_order(type, payload, room)
        @mutex.synchronize { (@queues[name.to_s] ||= []) << order }
        order
      end

      def pending?(name, type) = @mutex.synchronize { Array(@queues[name.to_s]).any? { |o| o.type == type } }

      def reports = @mutex.synchronize { @reports.dup }

      # Who is answering: by the age of the last report.
      def liveness(now = @clock.now)
        @mutex.synchronize do
          @members.keys.to_h do |name|
            report = @reports[name]
            last_seen = report&.at || @members[name]
            [name, last_seen && (now.to_f - last_seen.to_f) < REPORT_STALE ? :online : :offline]
          end
        end
      end

      def acked(type) = @mutex.synchronize { (@acks[type] || {}).keys }

      def clear_acks(type) = @mutex.synchronize { @acks[type] = {} }

      def last_exit=(record)
        @mutex.synchronize { @last_exit = record }
      end

      # --- the follower --------------------------------------------------------

      # Join this hunt (add_member 998). The id must be the open hunt's;
      # a name the roster does not expect is refused.
      def register(name, hunt_id:)
        @mutex.synchronize do
          raise ArgumentError, "hunt #{hunt_id} is not open" unless hunt_id == @hunt_id
          raise ArgumentError, "#{name} is not expected" unless @expected.is_a?(Integer) || @expected.include?(name.to_s)

          # Registration is a bounded first-report grace period. Without
          # it, the leader can declare a follower lost in the interval
          # between a successful join and that follower's first tick.
          @members[name.to_s] = @clock.now
          @queues[name.to_s] ||= []
          @hunt_id
        end
      end

      def report(name, report)
        report.at ||= @clock.now
        @mutex.synchronize do
          @reports[name.to_s] = report
          @leader_state.dup
        end
      end

      # Every order queued for this follower, oldest first, the queue emptied.
      def take_orders(name)
        @mutex.synchronize do
          queue = @queues[name.to_s]
          return [] unless queue

          taken = queue.dup
          queue.clear
          taken
        end
      end

      def ack(type, name, hunt_id:)
        @mutex.synchronize do
          raise ArgumentError, "hunt #{hunt_id} is not open" unless hunt_id == @hunt_id

          (@acks[type] ||= {})[name.to_s] = true
        end
      end

      private

      def make_order(type, payload, room)
        raise ArgumentError, "unknown order #{type}" unless ORDERS.include?(type)

        Order.new(type: type, hunt_id: @hunt_id, room: room, at: @clock.now, payload: payload)
      end
    end

    # The leader's view: what bigshot's leader asks its Group, answered
    # from the followers' reports. Followers that have stopped reporting
    # are left out of every wait (member_online 966 drops them; here
    # they are reported lost once and waited on no more).
    class Leader
      PULSE = Hub::PULSE

      attr_reader :hub, :policy, :name

      def initialize(hub, name:, policy: Policy.new, clock: Time)
        @hub = hub
        @name = name.to_s
        @policy = policy
        @clock = clock
        @lost = []
      end

      def hunt_id = @hub.hunt_id

      # bigshot solo? (7214): nobody registered.
      def solo? = @hub.members.empty?

      def followers = @hub.members

      def online = @hub.liveness(@clock.now).select { |_, state| state == :online }.keys

      # Followers gone quiet since last asked; each is reported once.
      def newly_lost
        offline = @hub.liveness(@clock.now).select { |_, state| state == :offline }.keys
        fresh = offline - @lost
        @lost = offline
        fresh
      end

      # bigshot size (1003): followers and the leader.
      def size = followers.size + 1

      # Current decision quorum: followers with fresh reports and the
      # leader. An offline registration must not keep an all-member
      # readiness policy waiting forever.
      def active_names = online + [@name]

      def fried_rest?(names) = @policy.fried_rest?(names, active_names: active_names)

      # The leader's state for the followers, every tick.
      def publish(world, phase:, target: nil)
        @last_state = {
          name: @name, room: world.room.id, phase: phase, looter: @looter,
          target: target && { id: target.id.to_s, name: target.name.to_s, noun: target.noun.to_s }
        }
        @hub.heartbeat!(@last_state)
      end

      # Liveness apart from the tick: an action that blocks longer than
      # HEARTBEAT_STALE (a sleep in a command list, a long roundtime, a
      # recovery) must not read as a dead leader to the followers. The
      # pulse repeats the last published state until stopped; the
      # engine's own watchdog is what notices stalled work.
      def keep_alive!(interval: PULSE)
        stop_pulse!
        @pulse = Thread.new do
          loop do
            sleep interval
            @hub.heartbeat!(@last_state) if @last_state
          end
        end
      end

      def stop_pulse!
        @pulse&.kill
        @pulse = nil
      end

      def order(type, payload = nil, room: nil)
        return nil if solo?

        @hub.broadcast(type, payload, room: room)
      end

      def prepare_movement(room)
        @hub.clear_acks(:prepare_move)
        order(:prepare_move, room: room)
      end

      def movement_ready?(world)
        all_present?(world) && !roundtime? && (online - @hub.acked(:prepare_move)).empty?
      end

      def reports
        live = online
        @hub.reports.select { |name, _| live.include?(name) }
      end

      # all_present? (1278): every follower in the room and in the game's
      # group.
      def all_present?(world)
        here = Array(world.room.players).map { |p| p.noun.to_s }
        grouped = world.group_nouns
        online.all? { |n| here.include?(n) && grouped.include?(n) }
      end

      def looting_done? = reports.values.none?(&:looting) # 1035
      def roundtime? = reports.values.any?(&:rt) # 1130
      def rest_prep_complete? = reports.values.all?(&:rest_prep_done) # 1291
      def need_sneaky? = reports.values.any? { |r| r.sneaky && !r.hidden } # 1264
      def any_wounded? = reports.values.any?(&:wounded) # 1300

      # group_should_rest? (1227): each follower's reason.
      def rest_reasons = reports.filter_map { |n, r| [n, r.rest_reason] if r.rest_reason }.to_h

      # group_should_hunt? (1197): each follower still not ready.
      def not_hunting_reasons = reports.filter_map { |n, r| [n, r.not_hunting_reason] if r.not_hunting_reason }.to_h

      # group_encumbrance (1252): weight still free per follower.
      def encumbrance = reports.transform_values { |r| r.encumbrance_left.to_i }

      # ma_looter (7119): the named looter when in the group; with
      # random_loot the least encumbered, the named one on a tie; else the
      # leader unless never_loot says so, else a follower at random.
      #
      # @param me_left [Integer] the leader's own free encumbrance
      def looter(me_left: 0)
        names = online + [@name]
        return @looter = @name if solo?

        unless @policy.looter.to_s.empty?
          found = names.find { |n| n =~ /#{Regexp.escape(@policy.looter.to_s)}/i }
          return @looter = found if found
        end
        never = @policy.never_loot_list
        if @policy.random_loot
          weights = encumbrance.merge(@name => me_left).reject { |n, _| never.include?(n) }
          best = weights.values.max
          candidates = weights.select { |_, v| v == best }.keys
          return @looter = (candidates.include?(@policy.looter.to_s) ? @policy.looter.to_s : candidates.sample) if candidates.any?
        end
        eligible = names - never
        @looter = eligible.include?(@name) ? @name : eligible.sample
      end

      def finish!(reason)
        @hub.broadcast(:hunt_over, reason) unless solo?
        @hub.leader_finished!(reason)
        @hub.last_exit = { reason: reason, hunt_id: hunt_id, at: @clock.now }
      end

      # --- the bounty (the split plan's 3.2 and 3.3) ------------------------

      # Each follower's bounty state from its report: :none, :hunting,
      # :complete or :failed; terminal states stick once seen.
      def bounty_states
        @bounty_states ||= {}
        reports.each { |n, r| @bounty_states[n] = r.bounty if r.bounty && !%i[complete failed].include?(@bounty_states[n]) }
        @bounty_states.dup
      end

      def reset_bounty! = @bounty_states = {}

      # Liveness first, then progress: a lost member ends the hunt before
      # anything else; complete only when every registered follower is
      # complete, failed or not on a bounty. +own+ is the leader's state.
      def verdict(own)
        return :member_lost if (followers - online).any?
        return :hunting if own == :hunting

        states = bounty_states
        return :hunting if followers.any? { |n| states[n].nil? || states[n] == :hunting }

        :bounty_complete
      end

      # The bounty child's decision from the verdict, so the leader's own
      # completion never rests the group while a follower is unfinished:
      # :member_lost (end the hunt), :rest (everyone is done), :hunt.
      #
      # @param own_complete [Boolean] the leader's own bounty_eval
      def bounty_decision(own_complete)
        case verdict(own_complete ? :complete : :hunting)
        when :member_lost then :member_lost
        when :bounty_complete then :rest
        else :hunt
        end
      end

      # The acknowledged shutdown: hunt_over to everyone, a wait for the
      # acks bounded by +deadline+ seconds, and an exit record naming who
      # never answered. Unclean when anyone is missing.
      def end_hunt(reason, deadline: 15)
        return finish!(reason) if solo?

        @hub.broadcast(:hunt_over, reason)
        stop_at = @clock.now + deadline
        loop do
          break if (followers - @hub.acked(:hunt_over)).empty?
          break if @clock.now >= stop_at

          sleep 0.25
        end
        unacked = followers - @hub.acked(:hunt_over)
        @hub.leader_finished!(reason)
        @hub.last_exit = { reason: reason, hunt_id: hunt_id, at: @clock.now, members: bounty_states, unacked: unacked, clean: unacked.empty? }
        Events.emit(:hunt_ended, reason: reason, unacked: unacked)
        @hub.last_exit
      end
    end

    # The follower's link to the Hub. Every call is bounded: a Hub that
    # does not answer within the deadline, or raises (the leader's Lich is
    # gone), marks the leader lost, and the caller gets the default.
    class Member
      DEADLINE = 3
      PULSE = Hub::PULSE

      attr_reader :name, :hunt_id

      def initialize(hub, name:, deadline: DEADLINE, clock: Time)
        @hub = hub
        @name = name.to_s
        @deadline = deadline
        @clock = clock
        @hunt_id = nil
        @lost = false
        @state = {}
      end

      def lost? = @lost

      # bigshot 10016-10027: join the open hunt; false until there is one.
      def register
        id = remote { @hub.hunt_id }
        return false if id.nil?

        @hunt_id = remote { @hub.register(@name, hunt_id: id) }
        !@hunt_id.nil?
      end

      def registered? = !@hunt_id.nil?

      def report(report)
        @last_report = report
        state = remote(false) { @hub.report(@name, report) }
        return false unless state

        @state = state
        true
      end

      # Liveness apart from the tick: the last report again, freshly
      # stamped, every +interval+ seconds, so an action that blocks
      # longer than REPORT_STALE does not read as a lost follower. The
      # leader's phase and target ride back on each answer.
      def keep_alive!(interval: PULSE)
        stop_pulse!
        @pulse = Thread.new do
          loop do
            sleep interval
            next unless @last_report

            again = @last_report.dup
            again.at = nil
            state = remote(false) { @hub.report(@name, again) }
            @state = state if state
          end
        end
      end

      def stop_pulse!
        @pulse&.kill
        @pulse = nil
      end

      # This hunt's orders, a stale attack dropped (10107).
      def orders(room:, now: @clock.now)
        Array(remote([]) { @hub.take_orders(@name) }).select do |o|
          o.hunt_id == @hunt_id && !(o.type == :attack && o.stale?(room, now))
        end
      end

      def ack(type)
        remote(false) { @hub.ack(type, @name, hunt_id: @hunt_id) }
      end

      def leader_state
        state = remote { @hub.leader_state }
        @state = state if state
        @state
      end

      def leader_name = @state[:name] || remote { @hub.leader_name }
      def leader_room = @state[:room]
      def leader_phase = @state[:phase]
      def leader_target = @state[:target]
      def looter = @state[:looter]

      def rooms = @rooms ||= remote({}) { @hub.rooms } || {}

      def leader_alive?
        return false if @lost

        remote(false) { @hub.leader_alive? } ? true : false
      end

      def finished_reason = remote { @hub.finished_reason }

      private

      # A remote call with a deadline; nil (or +default+) and a lost
      # leader on any failure.
      def remote(default = nil)
        result = default
        done = false
        thread = Thread.new do
          result = yield
          done = true
        rescue StandardError
          done = false
        end
        thread.join(@deadline)
        unless done
          thread.kill
          @lost = true
          return default
        end
        result
      end
    end
  end

  module Actions
    # GROUP OPEN, as bigshot sends it before every follower wait (7281).
    class GroupOpen < Base
      ANSWER = /Your group status is now (?:open|closed)|Your group status/

      def preconditions = me.dead? ? :dead : :ok
      def perform = send_and_match('group open', ANSWER, timeout: 3)
    end

    # DISBAND GROUP for independent travel (7262, 7501).
    class Disband < Base
      ANSWER = /You have no group to disband|You disband your group/

      def preconditions = me.dead? ? :dead : :ok
      def perform = send_and_match('disband group', ANSWER, timeout: 3)
    end

    # LEAVE GROUP, the follower's independent return (10080).
    class LeaveGroup < Base
      ANSWER = /You leave|But you are not in a group/

      def preconditions = me.dead? ? :dead : :ok
      def perform = send_and_match('leave group', ANSWER, timeout: 3)
    end

    # JOIN <leader> (group_all_followers 9312): the leader must be here.
    class Join < Base
      ANSWER = /You are already a member|You join|What were you referring to|group status is closed/

      def initialize(world, leader:, **opts)
        super(world, **opts)
        @leader = leader.to_s
      end

      def preconditions
        return :dead if me.dead?
        return :no_leader unless Array(@world.room.players).any? { |p| p.noun.to_s == @leader }

        :ok
      end

      def perform
        result = send_and_match("join #{@leader}", ANSWER, timeout: 3)
        return result unless result.success?
        return Result.new(status: :failed, reason: :not_here, line: result.line) if result.line =~ /What were you referring to/
        return Result.new(status: :failed, reason: :closed, line: result.line) if result.line =~ /closed/

        result
      end
    end
  end

  module Behaviors
    # The leader's holds between fights (do_hunt 7401-7413): stand every
    # follower down and wait for its movement acknowledgement, hold while
    # anyone is stunned or in roundtime, and call a missing follower back
    # before moving on. Followers gone quiet are reported once and no
    # longer waited on.
    class Muster < Behavior
      REORDER = 10

      def initialize(leader:, resting:, fight:, clock: Time)
        super()
        @leader = leader
        @resting = resting
        @fight = fight
        @clock = clock
        @called_at = nil
        @reason = nil
        @movement_room = nil
        @movement_requested = false
        @movement_ready = false
      end

      def priority = 15

      def wants_control?(world)
        @leader.newly_lost.each { |n| Events.emit(:follower_lost, name: n) }
        return false if @leader.solo? || @resting.call
        if @fight.call(world)
          reset_movement(world.room.id)
          return false
        end

        reset_movement(world.room.id) if @movement_room != world.room.id

        @reason = if EO::Engine::Survival::Predicates.group_member_stunned?(world) then :member_stunned
                  elsif @leader.roundtime? then :member_roundtime
                  elsif !@leader.all_present?(world) then :follower_missing
                  elsif !@movement_requested then :prepare_movement
                  elsif !@movement_ready then :movement_barrier
                  end
        !@reason.nil?
      end

      def tick(world)
        return nil if %i[member_stunned member_roundtime].include?(@reason)
        if @reason == :prepare_movement
          @leader.prepare_movement(world.room.id)
          @movement_requested = true
          return Actions::Result.new(status: :success, reason: :prepare_movement)
        end
        if @reason == :movement_barrier
          return nil unless @leader.movement_ready?(world)

          @movement_ready = true
          return Actions::Result.new(status: :success, reason: :movement_ready)
        end
        return nil if @called_at && @clock.now - @called_at < REORDER

        @called_at = @clock.now
        Events.emit(:waiting_for_followers, reason: @reason, room: world.room.id)
        Actions::GroupOpen.new(world).call
        Actions::Command.new(world, command: 'unhide').call if world.me.hidden?
        @leader.order(:follow_now, room: world.room.id)
        Actions::Result.new(status: :success, reason: :called_back)
      end

      private

      def reset_movement(room)
        @movement_room = room
        @movement_requested = false
        @movement_ready = false
      end
    end

    # The follower's Rest: the leader's orders, one step per tick, on
    # Rest's own step machinery (prep lists, trips, fog). The rooms come
    # from the leader's profile (return_waypoints_ids 1110, resting_id
    # 1115, hunting_id 1120, rally_ids 1125); the command and script lists
    # are the follower's own. A hunt_over is acked and reported.
    class Orders < Rest
      attr_reader :rest_prep_done

      # @param member [Group::Member]
      # @param assist [Behaviors::Assist, nil] told to attack and stand down
      # @param follow [Behaviors::Follow, nil] told to rejoin and to travel alone
      # @param loot [Behaviors::Loot, nil] assigned the loot
      # @param sneaky [Boolean] the follower's sneaky_sneaky
      def initialize(member:, policy:, counters: EO::Engine::Rest::Counters.new, assist: nil, follow: nil, loot: nil, sneaky: false,
                     travel: nil, fog: nil, scripts: nil, stance: nil, clock: Time)
        super(policy: policy, counters: counters, travel: travel, fog: fog, scripts: scripts, stance: stance, loot: nil, clock: clock)
        @member = member
        @assist = assist
        @follow = follow
        @loot = loot
        @sneaky = sneaky
        @queue = []
        @phase = :idle
        @rest_prep_done = false
        @commands = []
        @script_list = []
        @rooms = []
        @room = nil
        @after = nil
        @pending_ack = nil
      end

      def priority = 20

      def name = 'orders'

      # The follower never decides to rest; the leader's phase says.
      def resting? = @member.leader_phase == :resting

      def wants_control?(world)
        @queue.concat(@member.orders(room: world.room.id, now: @clock.now))
        @phase != :idle || @queue.any? || !@pending_ack.nil?
      end

      def tick(world)
        return step(world) unless @phase == :idle
        if @pending_ack
          return nil if world.me.in_rt? || world.me.in_cast_rt?

          type = @pending_ack
          @pending_ack = nil
          @member.ack(type)
          return Actions::Result.new(status: :success, reason: :movement_ready)
        end

        order = @queue.shift
        return nil if order.nil?

        Events.emit(:order, type: order.type, payload: order.payload)
        begin_order(world, order)
      end

      private

      def rooms = @member.rooms || {}

      def begin_order(world, order)
        case order.type
        when :attack then @assist&.attack!; nil
        when :follow_now then @assist&.stand_down!; @follow&.rejoin!; nil
        when :prepare_move
          @assist&.stand_down!
          @follow&.rejoin!
          @pending_ack = :prepare_move
          nil
        when :prep_rest
          @assist&.stand_down!
          @stance.call(@policy.wander_stance) if @policy.wander_stance
          Actions::Result.new(status: :success)
        when :hunting_prep then prep(@policy.hunting_prep_command_list, [])
        when :hunting_scripts_start then prep([], @policy.hunting_script_list)
        when :hunting_scripts_stop
          stop_hunting(world)
          Actions::Result.new(status: :success)
        when :cast_signs then nil # Maintain casts what is due
        when :check_sneaky then @sneaky && !world.me.hidden? ? Actions::Hide.new(world).call : nil
        when :go2_rally then travel(Array(rooms[:rally]))
        when :go2_hunting_room then room(rooms[:hunting])
        when :leave_group
          @follow&.independent!
          Actions::LeaveGroup.new(world).call
        when :fog_return
          @reason = 'ordered'
          @phase = :fog
          nil
        when :go2_waypoints then travel(Array(rooms[:waypoints]))
        when :go2_resting_room then room(rooms[:resting])
        when :resting_prep
          @rest_prep_done = false
          @counters.reset!
          prep(@policy.resting_command_list, [])
        when :resting_scripts_start
          @after = -> { @rest_prep_done = true }
          prep([], @policy.resting_script_list)
        when :loot
          if order.payload.to_s == @member.name
            @assist&.stand_down!
            @loot&.assign!
          end
          nil
        when :unhide then world.me.hidden? ? Actions::Command.new(world, command: 'unhide').call : nil
        when :follower_overkill then overkill(world)
        when :hunt_over
          @member.ack(:hunt_over)
          Events.emit(:hunt_over, reason: order.payload)
          nil
        when :command then Actions::Command.new(world, command: order.payload.to_s).call
        end
      end

      def prep(commands, scripts)
        @commands = commands
        @script_list = scripts
        @remaining = nil
        @phase = :prep
        nil
      end

      def travel(list)
        @rooms = list
        @remaining = nil
        @phase = :travel
        nil
      end

      def room(id)
        @room = id
        @attempts = 0
        @phase = :room
        nil
      end

      def step(world)
        result = case @phase
                 when :prep then step_prep(world, @commands, @script_list, :idle)
                 when :travel then step_travel(world, @rooms, :idle)
                 when :room then step_room(world, @room, :idle)
                 when :fog then step_fog(world)
                 when :custom_fog then step_custom_fog(world)
                 end
        if @phase == :idle && @after
          @after.call
          @after = nil
        end
        result
      end

      # Rest's fixed successors, redirected to idle.
      def after_fog = :idle
      def stuck_phase(_next_phase) = :idle
      def finish = (@phase = :idle)

      # FOLLOWER_OVERKILL (add_event 2887, use_lte_boost 10100): the
      # leader's kill counts here too.
      def overkill(world)
        boost = Actions::LteBoost.new(world, counters: @counters, policy: @policy).call
        return boost if boost.success?

        if EO::Engine::Rest::Predicates.fried?(world.me, @policy) && EO::Engine::Rest::Predicates.lte_boosts_spent?(@counters, @policy)
          @counters.overkill += 1
          Events.emit(:overkill, count: @counters.overkill, max: @policy.overkill_max)
        end
        Actions::Result.new(status: :success, reason: :counted)
      end
    end

    # The follower's Engage (the tail's :ATTACK loop 10105-10149): after
    # an attack order, the leader's target while it stands, else our own
    # choice by the same rules, until the leader says move or loot. Never
    # without the leader in the room (7794; should_flee? 8543 refuses a
    # fight with nobody here).
    class Assist < Engage
      def initialize(member:, **opts)
        super(**opts)
        @member = member
        @attacking = false
      end

      def name = 'assist'

      def attack! = @attacking = true
      def stand_down! = @attacking = false
      def attacking? = @attacking

      def wants_control?(world)
        return false unless @attacking
        return false unless leader_here?(world)

        !next_target(world).nil?
      end

      private

      def leader_here?(world)
        leader = @member.leader_name.to_s
        Array(world.room.players).any? { |p| p.noun.to_s == leader }
      end

      # 10124-10135: the leader's target when it is here and alive, else
      # ours; a better rank still takes over with priority.
      def next_target(world)
        wanted = @member.leader_target
        return nil unless wanted

        leaders = Array(world.room.targets).find { |t| t.id.to_s == wanted[:id].to_s }
        return nil unless leaders && leaders.status.to_s !~ /dead|gone/

        Targets.choose(world.room.targets, @targets_policy, current: leaders, priority: @policy.priority)
      end
    end

    # The follower's Wander (group_all_followers 9305): not with the
    # leader, go2 the leader's room; there and not in the group, JOIN.
    # After a leave_group order the follower travels on its own orders
    # until the next follow_now.
    class Follow < Behavior
      def initialize(member:, travel: nil, clock: Time)
        super()
        @member = member
        @travel = travel || EO::Engine::Travel.default
        @clock = clock
        @trip = nil
        @independent = false
        @rejoin = false
      end

      def priority = 60

      def name = 'follow'

      def cancel! = EO::Engine::Travel.cancel(self)
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      def rejoin!
        @rejoin = true
        @independent = false
      end

      def independent! = @independent = true

      def wants_control?(world)
        return false if @independent
        return true if @trip

        !leader_here?(world) || !grouped?(world)
      end

      def tick(world)
        if world.me.in_rt? || world.me.in_cast_rt?
          return Actions::Result.new(status: :skipped, reason: :roundtime)
        end

        unless leader_here?(world)
          room = @member.leader_room
          return Actions::Result.new(status: :failed, reason: :no_leader_room) if room.nil?
          return Actions::Result.new(status: :success, reason: :leader_room) if room == world.room.id

          case EO::Engine::Travel.step(self, @travel, room, world)
          when :underway then return nil
          when :arrived then return Actions::Result.new(status: :success, reason: :arrived)
          else return Actions::Result.new(status: :failed, reason: :could_not_reach)
          end
        end
        return Actions::Join.new(world, leader: @member.leader_name).call unless grouped?(world)

        @rejoin = false
        nil
      end

      private

      def leader_here?(world)
        leader = @member.leader_name.to_s
        Array(world.room.players).any? { |p| p.noun.to_s == leader }
      end

      def grouped?(world)
        leader = @member.leader_name.to_s
        world.group_leader_noun.to_s == leader || world.group_nouns.include?(leader)
      end
    end
  end
end
