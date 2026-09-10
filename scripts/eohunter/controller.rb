# frozen_string_literal: true

# Native, exact-instance supervision for agent-run hunts. LAB owns admission and
# the expiring lease; eohunter continues to own combat, travel, rest and cleanup.
module EO::Engine
  module Controller
    class Invalid < StandardError; end

    module Immutable
      module_function

      def copy(value)
        result = case value
                 when Hash then value.each_with_object({}) { |(key, item), out| out[key] = copy(item) }
                 when Array then value.map { |item| copy(item) }
                 when String then value.dup
                 else value
                 end
        result.freeze
      end
    end

    START_FLAG = '--supervised-start-v1'
    REFUGE_FLAG = '--supervised-refuge-v1'

    Launch = Struct.new(:work_deadline, :cleanup_deadline, :refuge_room, :return_deadline, keyword_init: true) do
      def self.extract!(arguments, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        args = arguments.dup
        start_values = remove_pair(args, START_FLAG)
        refuge_values = remove_pair(args, REFUGE_FLAG)
        return [nil, args] unless start_values || refuge_values
        raise Invalid, 'both supervised controller selectors are required' unless start_values && refuge_values

        work, cleanup = numeric_pair(start_values, 'execution window')
        room, return_at = refuge_pair(refuge_values)
        now = clock.call
        unless now.is_a?(Numeric) && now.finite? && work > now && cleanup > work && cleanup - work <= 10 &&
               return_at > cleanup && (return_at - cleanup).between?(10, 120) && return_at - now <= 300
          raise Invalid, 'supervised controller deadlines are invalid or expired'
        end

        [new(work_deadline: work, cleanup_deadline: cleanup, refuge_room: room, return_deadline: return_at).freeze, args]
      end

      def admit_profile!(profile)
        unless profile['resting_room_id'].is_a?(Integer) && profile['resting_room_id'] == refuge_room &&
               profile['hunting_room_id'].is_a?(Integer) && !profile['hunting_boundaries'].empty?
          raise Invalid, 'controlled hunt requires a bounded profile whose resting room is the registered refuge'
        end
        if profile['loot_script'] || !profile['resting_scripts'].empty? || !profile['hunting_scripts'].empty?
          raise Invalid, 'controlled hunt does not yet admit profile child scripts; use native looting and commands'
        end
        if profile['dead_man_switch'] || profile['depart_switch']
          raise Invalid, 'controlled hunt cannot log out or depart on death'
        end
        true
      end

      class << self
        private

        def remove_pair(args, flag)
          indexes = args.each_index.select { |index| args[index] == flag }
          raise Invalid, "#{flag} must occur exactly once" if indexes.length > 1
          return nil if indexes.empty?

          index = indexes.first
          raise Invalid, "#{flag} requires one value" unless args[index + 1] && !args[index + 1].start_with?('--')
          args.slice!(index, 2).last
        end

        def numeric_pair(value, label)
          parts = value.to_s.split(',', -1)
          raise Invalid, "#{label} must contain exactly two deadlines" unless parts.length == 2

          numbers = parts.map { |part| Float(part, exception: false) }
          raise Invalid, "#{label} deadlines must be finite" unless numbers.all? { |number| number&.finite? }

          numbers
        end

        def refuge_pair(value)
          room, return_at = value.to_s.split(',', -1)
          unless room&.match?(/\A[1-9]\d*\z/) && room != '4'
            raise Invalid, 'supervised refuge must be an explicit room other than 4'
          end
          deadline = Float(return_at, exception: false)
          raise Invalid, 'supervised refuge deadline must be finite' unless deadline&.finite?

          [room.to_i, deadline]
        end
      end
    end

    # A finite, predeclared sequence of profile routines. LAB may choose only a
    # manifest-enumerated sequence; eohunter owns target selection, execution,
    # measurement and the decision to stop exposing the character.
    class TrialSequence
      KEYWORD = 'trial'
      MAX_TRIALS = 5
      MAX_ACTIONS_PER_TRIAL = 12
      MAX_SECONDS_PER_TRIAL = 45

      attr_reader :failure

      def self.extract!(arguments, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        args = arguments.dup
        indexes = args.each_index.select { |index| args[index].to_s.casecmp?(KEYWORD) }
        raise Invalid, 'trial may occur only once' if indexes.length > 1
        return [nil, args] if indexes.empty?

        index = indexes.first
        value = args[index + 1]
        raise Invalid, 'trial requires a comma-separated routine sequence' if value.nil?

        routines = value.to_s.downcase.split(/[,-]/, -1)
        unless routines.length.between?(1, MAX_TRIALS) && routines.all? { |letter| letter.match?(/\A[a-j]\z/) }
          raise Invalid, "trial routines must be 1-#{MAX_TRIALS} letters from a through j"
        end
        args.slice!(index, 2)
        [new(routines, clock: clock), args]
      end

      def initialize(routines, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @routines = Array(routines).map(&:to_s).freeze
        @clock = clock
        @mutex = Mutex.new
        @cursor = 0
        @results = []
        @active = nil
        @failure = nil
      end

      def admit_profile!(profile)
        missing = @routines.uniq.reject do |letter|
          key = letter == 'a' ? 'hunting_commands' : "hunting_commands_#{letter}"
          Array(profile[key]).any?
        end
        raise Invalid, "trial routines are empty in the reviewed profile: #{missing.join(', ')}" if missing.any?

        true
      end

      # Injected into Engage at its existing routine-selection seam.
      def select(creature, _default)
        @mutex.synchronize do
          raise Invalid, 'trial sequence is already complete' if complete_locked?
          id = creature.id.to_s
          if @active && @active[:target_id] != id
            raise Invalid, 'eohunter changed targets before the active trial was resolved'
          end
          @active ||= {
            index: @cursor + 1, routine: @routines.fetch(@cursor), target_id: id,
            creature: creature_data(creature), started_at: @clock.call,
            actions: [], samples: []
          }
          @active[:routine]
        end
      end

      # Called once per owner-thread controller checkpoint, before another
      # engine action. Returns :complete, :failed, or nil.
      def tick(world)
        @mutex.synchronize do
          return :failed if @failure
          return :complete if complete_locked?
          return nil unless @active

          target = Array(world.room.targets).find { |item| item.id.to_s == @active[:target_id] }
          if target
            sample_locked(world, target)
            if @active[:actions].length >= MAX_ACTIONS_PER_TRIAL || @clock.call - @active[:started_at] >= MAX_SECONDS_PER_TRIAL
              finish_locked(world, target, 'limit_reached')
              @active = nil
              @failure = 'trial_limit_reached'
              return :failed
            end
            return nil
          end

          observed = Array(world.room.creatures).find { |item| item.id.to_s == @active[:target_id] }
          outcome = observed&.status.to_s.match?(/dead/i) ? 'killed' : 'target_lost'
          finish_locked(world, observed, outcome)
          unless outcome == 'killed'
            @active = nil
            @failure = outcome
            return :failed
          end

          @cursor += 1
          @active = nil
          complete_locked? ? :complete : nil
        end
      end

      def observe(event)
        return unless event.type == :routine_action_resolved

        @mutex.synchronize do
          return unless @active && event.data[:target].to_s == @active[:target_id]

          @active[:actions] << action_data(event)
        end
      end

      def status
        @mutex.synchronize do
          Immutable.copy(
            state: @failure ? 'failed' : (complete_locked? ? 'complete' : 'running'),
            planned: @routines, current: @active && @active[:index],
            failure: @failure, results: @results, active: @active
          )
        end
      end

      private

      def complete_locked? = @cursor >= @routines.length && @active.nil?

      def creature_data(creature)
        return {} unless creature

        %i[id name noun type status].to_h do |key|
          value = creature.respond_to?(key) ? creature.public_send(key) : nil
          [key, value.nil? ? nil : value.to_s]
        end
      end

      def resources(world)
        %i[mana health spirit stamina].to_h do |name|
          value = world.me.respond_to?(name) ? world.me.public_send(name) : nil
          [name, value.nil? ? nil : value.to_i]
        end
      end

      def sample_locked(world, target)
        state = world.respond_to?(:creature_state) ? world.creature_state(@active[:target_id]) : nil
        sample = { at: @clock.call, resources: resources(world), creature: creature_data(target), state: state }
        comparable = sample.reject { |key, _| key == :at }
        previous = @active[:samples].last
        @active[:samples] << sample if previous.nil? || previous.reject { |key, _| key == :at } != comparable
        @active[:samples].shift while @active[:samples].length > MAX_ACTIONS_PER_TRIAL + 2
      end

      def action_data(event)
        before = Hash(event.data[:resources_before])
        after = Hash(event.data[:resources_after])
        spent = before.each_with_object({}) do |(name, value), out|
          next if value.nil? || after[name].nil?

          out[name] = [value.to_i - after[name].to_i, 0].max
        end
        {
          at: event.at.to_f, command: event.data[:command].to_s[0, 200],
          status: event.data[:status].to_s, reason: event.data[:reason]&.to_s,
          line: event.data[:line].to_s[0, 300], spent: spent
        }
      end

      def finish_locked(world, creature, outcome)
        sample_locked(world, creature) if creature
        finished = @active.merge(
          outcome: outcome, finished_at: @clock.call,
          elapsed_seconds: (@clock.call - @active[:started_at]).round(3),
          final_resources: resources(world),
          final_creature_state: (world.respond_to?(:creature_state) ? world.creature_state(@active[:target_id]) : nil)
        )
        @results << finished
      end
    end

    # Sticky lease and state guard shared by the owner and its exact go2 child.
    # Any failed observation permanently revokes the run.
    class Guard
      attr_reader :sends

      def initialize(owner:, snapshot:, launch:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @owner, @snapshot, @launch, @clock = owner, snapshot, launch, clock
        @mutex = Mutex.new
        @predicate = nil
        @activated = false
        @revoked = false
        @phase = :work
        @sends = 0
      end

      def activate(predicate)
        return false unless predicate.is_a?(Proc)

        @mutex.synchronize do
          return false if @predicate || @revoked

          @predicate = predicate
        end
        valid = valid_observation?(predicate, :work, nil)
        @mutex.synchronize do
          @activated = valid
          @revoked = true unless valid
        end
        valid
      end

      def activated? = @mutex.synchronize { @activated && !@revoked }

      def phase=(value)
        @mutex.synchronize { @phase = value }
      end

      def permitted?(wire)
        predicate, phase, activated, revoked = @mutex.synchronize { [@predicate, @phase, @activated, @revoked] }
        return false if revoked || !activated || !predicate

        valid = valid_observation?(predicate, phase, wire)
        unless valid
          revoke!
          return false
        end
        @mutex.synchronize { @sends += 1 unless wire.nil? }
        true
      rescue StandardError
        revoke!
        false
      end

      def bind_session!(session)
        value = session.to_s
        raise Invalid, 'controlled session identity is unavailable' if value.empty?

        @mutex.synchronize do
          raise Invalid, 'controlled session is already bound' if @session

          @session = value.freeze
        end
      end

      def revoke!
        @mutex.synchronize { @revoked = true }
        false
      end

      def revoked? = @mutex.synchronize { @revoked }

      private

      def valid_observation?(predicate, phase, wire)
        return false unless predicate.call == true

        now = @clock.call
        limit = phase == :return ? @launch.return_deadline : @launch.work_deadline
        observed = @snapshot.call
        valid = now.is_a?(Numeric) && now.finite? && now < limit && observed.is_a?(Hash) &&
                observed[:owner] == true && observed[:connected] == true && observed[:alive] == true &&
                observed[:session] == @session
        valid &&= observed[:stable] == true unless wire.nil?
        valid
      end
    end

    # The only child-process seam admitted by the first controller version.
    # It owns exact handles; it never kills or exempts a script by name alone.
    class ChildScripts
      ALLOWED = ['go2'].freeze

      def initialize(owner:, guard:)
        @owner, @guard = owner, guard
        @mutex = Mutex.new
        @children = {}
      end

      def start(name, args = nil)
        key = name.to_s.downcase
        raise Invalid, "controlled child #{key} is not admitted" unless ALLOWED.include?(key)
        raise Invalid, "controlled child #{key} is already running" if running?(key)

        child = Script.start_child(key, args, quiet: true,
                                              execution_guard: ->(wire) { @guard.permitted?(wire) },
                                              allow_script_starts: false)
        raise Invalid, "controlled child #{key} did not start" unless child

        @mutex.synchronize { @children[key] = child }
        child
      end

      def running?(name)
        child = @mutex.synchronize { @children[name.to_s.downcase] }
        child && child.respond_to?(:running?) && child.running? && !child.stopping?
      end

      def paused?(name)
        child = @mutex.synchronize { @children[name.to_s.downcase] }
        child && child.respond_to?(:paused?) && child.paused?
      end

      def kill(name)
        child = @mutex.synchronize { @children[name.to_s.downcase] }
        return false unless child

        child.kill(async: true) unless child.join(0)
        true
      end

      def active_travel_child?(candidate)
        child = @mutex.synchronize { @children['go2'] }
        child && child.equal?(candidate) && @owner.child_scripts.any? { |owned| owned.equal?(candidate) } && running?('go2')
      end

      def cleanup(timeout: 2)
        children = @mutex.synchronize { @children.values.dup }
        children.all? do |child|
          next true if child.join(0)

          child.respond_to?(:kill_sync) && child.kill_sync(timeout: timeout)
        end
      end
    end

    # Owner-thread state machine exposed to LAB. It does not implement hunting;
    # it supervises Engine and asks Rest to perform its existing return cycle.
    class Runtime
      CONTROLS = %w[status hold resume stop retreat].freeze
      MAILBOX_CAPACITY = 32
      OBSERVATION_CAPACITY = 128

      def initialize(engine:, rest:, world:, owner:, guard:, children:, launch:, objective:,
                     snapshot:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @engine, @rest, @world, @owner = engine, rest, world, owner
        @guard, @children, @launch, @objective, @snapshot, @clock = guard, children, launch, objective, snapshot, clock
        @thread = Thread.current
        @mutex = Mutex.new
        @mailbox = []
        @observations = []
        @state, @phase, @reason = :starting, 'outbound', nil
        origin = verified_snapshot!
        @origin_hands = Immutable.copy(origin[:hands])
        @guard.bind_session!(origin[:session])
        @event_handler = Events.on(:any) { |event| record(event) }
        cache_status
      end

      def status = @mutex.synchronize { @cached_status }

      def activate_supervised(valid:)
        @guard.activate(valid)
      end

      def request(action, valid: nil)
        name = action.to_s
        @mutex.synchronize do
          return response(false, 'invalid_control_predicate') unless valid.nil? || valid.is_a?(Proc)
          return response(false, 'unknown_control') unless CONTROLS.include?(name)
          return response(true) if name == 'status'
          return response(false, 'run_closed') if terminal?
          return response(false, 'control_queue_full') if @mailbox.length >= MAILBOX_CAPACITY

          @mailbox << [name.freeze, valid].freeze
          response(true)
        end
      end

      def run
        assert_owner_thread!
        await_supervisor!
        @state = :running
        @rest.start!
        Events.emit(:engine_started, behaviors: @engine.status[:behaviors])
        until terminal?
          drain_controls
          request_return('operation_work_deadline') if @phase != 'returning' && @clock.call >= @launch.work_deadline
          unless @guard.permitted?(nil)
            fail_closed('controller_authority_lost')
            break
          end
          if @phase == 'working'
            case @objective.tick(@world)
            when :complete then request_return('objective_complete', final_loot: true)
            when :failed then request_return("objective_failed:#{@objective.failure}")
            end
          end
          if @phase == 'returning' && finish_return_if_ready
            break
          end
          guarded_tick
          if @engine.stopping? && !terminal?
            fail_closed(@engine.stop_reason || 'engine_stopped')
          elsif @phase == 'outbound' && @rest.phase == :hunting
            @phase = 'working'
          end
          cache_status
        end
        status
      ensure
        Events.emit(:engine_stopped, reason: @reason) if @state != :starting
        Events.off(@event_handler) if @event_handler
        @children.cleanup
        cache_status
      end

      def close
        fail_closed('controller_closed') unless terminal?
        status
      end

      private

      def terminal? = %i[completed stopped].include?(@state)

      def response(accepted, reason = nil)
        { accepted: accepted, reason: reason, status: @cached_status }.compact.freeze
      end

      def await_supervisor!
        deadline = @clock.call + 3
        until @guard.activated?
          raise Invalid, 'supervised controller startup expired' if @clock.call >= deadline

          observed = @snapshot.call
          unless observed.is_a?(Hash) && observed[:owner] == true && observed[:connected] == true &&
                 observed[:room_id] == @launch.refuge_room && observed[:hands] == @origin_hands
            raise Invalid, 'supervised controller start state changed before activation'
          end
          @owner.execution_sleep(0.01)
        end
      end

      def drain_controls
        MAILBOX_CAPACITY.times do
          action, valid = @mutex.synchronize { @mailbox.shift }
          break unless action
          unless valid.nil? || valid.call == true
            @control_error = 'control_expired_or_revoked'
            next
          end

          case action
          when 'resume'
            @control_error = @phase == 'working' ? nil : 'return_already_started'
            @engine.resume! if @phase == 'working'
          when 'hold', 'stop', 'retreat'
            request_return("manual_#{action}")
          end
        rescue StandardError
          @control_error = 'control_expired_or_revoked'
        end
      end

      def request_return(reason, final_loot: false)
        return if @phase == 'returning'

        work_state = reason == 'objective_complete' ? :completed : :stopped
        @work_result = Immutable.copy(state: work_state, reason: reason, observations: @observations.dup)
        @phase = 'returning'
        @guard.phase = :return
        @engine.resume!
        @rest.request_return!(reason, final_loot: final_loot)
      end

      def guarded_tick
        policy = ->(wire) { @guard.permitted?(wire) }
        @owner.with_execution_guard(policy, allow_script_starts: true) { @engine.tick }
      rescue StandardError
        fail_closed(@guard.revoked? ? 'controller_authority_lost' : 'guarded_engine_error')
      end

      def finish_return_if_ready
        return false unless @rest.phase == :resting

        observed = @snapshot.call
        returned = observed.is_a?(Hash) && observed[:room_id] == @launch.refuge_room &&
                   observed[:stable] == true && observed[:destination_safe] == true
        restored = returned && observed[:standing] == true && observed[:hands] == @origin_hands
        @refuge_returned, @equipment_restored = returned, restored
        @engine.stop!(restored ? :controller_complete : :controller_handoff_failed)
        work_complete = @work_result.is_a?(Hash) && @work_result[:state] == :completed
        @state = restored && work_complete ? :completed : :stopped
        @reason = if !restored then 'refuge_equipment_unconfirmed'
                  elsif work_complete then 'completed'
                  else 'retreated'
                  end
        @phase = 'finished'
        cache_status
        true
      end

      def fail_closed(reason)
        @guard.revoke!
        @engine.stop!(reason)
        @state = :stopped
        @reason = reason
        @phase = 'finished'
        cache_status
      end

      def verified_snapshot!
        observed = @snapshot.call
        unless observed.is_a?(Hash) && observed[:room_id] == @launch.refuge_room && observed[:stable] == true &&
               observed[:destination_safe] == true && observed[:alive] == true && observed[:standing] == true &&
               observed[:owner] == true && observed[:connected] == true && observed[:hands].is_a?(Array) &&
               observed[:hands].length == 2 && observed[:hands].all? { |id| id.nil? || id.to_s.match?(/\A[1-9]\d*\z/) }
          raise Invalid, 'controller must start alive, standing, equipped and stable in its registered refuge'
        end
        observed
      end

      def record(event)
        @objective.observe(event)
        observation = { sequence: @observation_sequence = @observation_sequence.to_i + 1,
                        type: event.type.to_s, at: event.at.to_f,
                        data: scalar_data(event.data) }.freeze
        @mutex.synchronize do
          @observations << observation
          @observations.shift while @observations.length > OBSERVATION_CAPACITY
        end
        cache_status
      rescue StandardError
        nil
      end

      def scalar_data(data)
        Hash(data).each_with_object({}) do |(key, value), result|
          result[key.to_s] = case value
                             when String, Numeric, true, false, nil then value
                             else value.to_s
                             end
        end.freeze
      end

      def cache_status
        engine_status = @engine.status
        observed = @snapshot.call rescue {}
        value = {
          mode: 'hunt', state: @state, reason: @reason,
          behavior: engine_status[:behavior], room_id: observed[:room_id],
          retreat_pending: @phase == 'returning', control_error: @control_error,
          work_result: @work_result,
          objective: @objective.status,
          refuge: { room_id: @launch.refuge_room, phase: @phase,
                    returned: @refuge_returned == true, equipment_restored: @equipment_restored == true },
          observations: @mutex.synchronize { @observations.dup },
          timing: { updated_at: @clock.call, work_deadline: @launch.work_deadline,
                    cleanup_deadline: @launch.cleanup_deadline, return_deadline: @launch.return_deadline }
        }
        frozen = Immutable.copy(value)
        @mutex.synchronize { @cached_status = frozen }
        frozen
      end

      def assert_owner_thread!
        raise ThreadError, 'controller lifecycle must run on the eohunter owner thread' unless Thread.current.equal?(@thread)
      end
    end
  end
end
