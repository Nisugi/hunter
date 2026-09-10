# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Controller do
  # rubocop:disable Lint/ConstantDefinitionInBlock
  class ControllerClock
    attr_reader :now

    def initialize(now = 100.0) = @now = now
    def advance(seconds) = @now += seconds
  end

  class ControllerOwner
    attr_reader :child_scripts

    def initialize(clock)
      @clock = clock
      @child_scripts = []
      @stopping = false
    end

    def with_execution_guard(policy, allow_script_starts: true)
      raise 'guard denied' unless allow_script_starts && policy.call(nil)

      yield
    end

    def execution_sleep(seconds) = @clock.advance(seconds)
    def stopping? = @stopping
  end

  class ControllerRest
    attr_reader :phase, :reason

    def initialize = @phase = :hunting
    def start! = @phase = :hunting_prep

    def request_return!(reason, final_loot: false)
      @reason = reason
      @final_loot = final_loot
      @phase = :leave
    end

    def advance
      @phase = case @phase
               when :hunting_prep then :hunting
               when :leave then :resting
               else @phase
               end
    end

    def tick(_world) = advance
  end

  class ControllerEngine
    attr_accessor :stop_after_ticks
    attr_reader :stop_reason

    def initialize(clock, rest)
      @clock, @rest = clock, rest
      @stopping = @paused = false
      @ticks = 0
    end

    def status
      { state: @stopping ? :stopped : :running, reason: @stop_reason,
        behavior: @rest.phase.to_s, behaviors: %w[rest engage wander], consecutive_failures: 0 }
    end

    def tick
      @rest.advance
      @clock.advance(1)
      @ticks += 1
      stop!(:repeated_failures) if @stop_after_ticks && @ticks >= @stop_after_ticks
    end

    def stop!(reason)
      @stopping = true
      @stop_reason ||= reason
    end

    def stopping? = @stopping
    def resume! = @paused = false
  end

  class ControllerChildren
    def cleanup = true
  end

  class ControllerObjective
    attr_reader :failure

    def tick(_world) = nil
    def observe(_event) = nil
    def status = { state: 'running', results: [] }
  end

  class CompletingControllerObjective < ControllerObjective
    def tick(_world) = :complete
    def status = { state: 'complete', results: [{ routine: 'a', outcome: 'killed' }] }
  end

  def launch(clock, work: 2)
    EO::Engine::Controller::Launch.new(work_deadline: clock.now + work,
                                       cleanup_deadline: clock.now + work + 5,
                                       refuge_room: 1000,
                                       return_deadline: clock.now + work + 20).freeze
  end

  def runtime_fixture(work: 2, objective: ControllerObjective.new)
    clock = ControllerClock.new
    owner = ControllerOwner.new(clock)
    rest = ControllerRest.new
    engine = ControllerEngine.new(clock, rest)
    state = { session: 'session-1', room_id: 1000, room_epoch: 1, owner: true,
              connected: true, alive: true, standing: true, hands: %w[10 11],
              stable: true, destination_safe: true }
    selected = launch(clock, work: work)
    snapshot = -> { state.dup }
    guard = EO::Engine::Controller::Guard.new(owner: owner, snapshot: snapshot,
                                              launch: selected, clock: -> { clock.now })
    runtime = EO::Engine::Controller::Runtime.new(engine: engine, rest: rest, world: Object.new,
                                                  owner: owner, guard: guard, children: ControllerChildren.new,
                                                  launch: selected, objective: objective,
                                                  snapshot: snapshot, clock: -> { clock.now })
    { runtime: runtime, guard: guard, state: state, clock: clock, engine: engine, rest: rest }
  end

  describe EO::Engine::Controller::Launch do
    it 'extracts the private selectors without exposing them to profile options' do
      clock = -> { 100.0 }
      selected, remaining = described_class.extract!(
        %w[--supervised-start-v1 120,125 --supervised-refuge-v1 1000,145], clock: clock
      )
      expect(remaining).to eq([])
      expect(selected.refuge_room).to eq(1000)
      expect(selected.work_deadline).to eq(120.0)
    end

    it 'preserves ordinary eohunter arguments when no private selector exists' do
      selected, remaining = described_class.extract!(%w[Ordinary-Profile bandits])
      expect(selected).to be_nil
      expect(remaining).to eq(%w[Ordinary-Profile bandits])
    end

    it 'rejects partial, duplicate, expired and malformed selectors' do
      cases = [
        %w[--supervised-start-v1 120,125],
        %w[--supervised-start-v1 120,125 --supervised-start-v1 121,126 --supervised-refuge-v1 1000,145],
        %w[--supervised-start-v1 99,105 --supervised-refuge-v1 1000,125],
        %w[--supervised-start-v1 120,125 --supervised-refuge-v1 4,145]
      ]
      cases.each do |arguments|
        expect { described_class.extract!(arguments, clock: -> { 100.0 }) }.to raise_error(EO::Engine::Controller::Invalid)
      end
    end

    it 'admits only bounded profiles returning to the registered refuge without child scripts' do
      selected = described_class.new(work_deadline: 120, cleanup_deadline: 125,
                                     refuge_room: 1000, return_deadline: 145)
      profile = Hash.new { |_hash, _key| false }
      profile.update('resting_room_id' => 1000, 'hunting_room_id' => 1001,
                     'hunting_boundaries' => [1009], 'loot_script' => nil,
                     'resting_scripts' => [], 'hunting_scripts' => [],
                     'dead_man_switch' => false, 'depart_switch' => false)
      expect(selected.admit_profile!(profile)).to be(true)
      profile['loot_script'] = 'eloot'
      expect { selected.admit_profile!(profile) }.to raise_error(EO::Engine::Controller::Invalid, /child scripts/)
    end
  end

  describe EO::Engine::Controller::TrialSequence do
    TrialNpc = Struct.new(:id, :name, :noun, :type, :status)

    it 'extracts only a short sequence of profile routine letters' do
      trial, remaining = described_class.extract!(%w[trial a,c,b tail])
      expect(remaining).to eq(['tail'])
      expect(trial.status[:planned]).to eq(%w[a c b])
      expect { described_class.extract!(%w[trial a,z]) }.to raise_error(EO::Engine::Controller::Invalid)
    end

    it 'rejects a sequence whose reviewed profile routines are empty' do
      trial, = described_class.extract!(%w[trial a,b])
      profile = { 'hunting_commands' => ['702'], 'hunting_commands_b' => [] }
      expect { trial.admit_profile!(profile) }.to raise_error(EO::Engine::Controller::Invalid, /b/)
    end

    it 'assigns one routine per creature and records bounded action evidence' do
      clock = ControllerClock.new
      trial, = described_class.extract!(%w[trial a,b], clock: -> { clock.now })
      me = OpenStruct.new(mana: 100, health: 120, spirit: 10, stamina: 80)
      first = TrialNpc.new('1', 'a rat', 'rat', 'undead', 'standing')
      room = OpenStruct.new(targets: [first], creatures: [first])
      world = OpenStruct.new(me: me, room: room)
      instance = OpenStruct.new(essential_data: { damage_taken: 20, status: { 'stunned' => true } })
      world.define_singleton_method(:creature) { |_id| instance }

      expect(trial.select(first, 'j')).to eq('a')
      event = EO::Engine::Events::Event.new(type: :routine_action_resolved, at: Time.at(100), data: {
        target: '1', command: '702', status: :success, reason: nil, line: 'Cast Roundtime 3 Seconds.',
        resources_before: { mana: 100 }, resources_after: { mana: 96 }
      })
      trial.observe(event)
      first.status = 'dead'
      room.targets = []
      expect(trial.tick(world)).to be_nil

      second = TrialNpc.new('2', 'another rat', 'rat', 'undead', 'standing')
      room.targets = [second]
      room.creatures = [second]
      expect(trial.select(second, 'j')).to eq('b')
      second.status = 'dead'
      room.targets = []
      expect(trial.tick(world)).to eq(:complete)
      expect(trial.status[:results].map { |result| result[:routine] }).to eq(%w[a b])
      expect(trial.status[:results].first[:actions].first[:spent]).to eq(mana: 4)
      expect(trial.status[:results].first[:final_creature_state]).to include(damage_taken: 20, status: { 'stunned' => true })
      expect(instance.essential_data[:status]).not_to be_frozen
    end
  end

  describe EO::Engine::Controller::ChildScripts do
    it 'retains exact travel-child identity while the adopted child tears down' do
      child = instance_double('ScriptChild', running?: false, stopping?: true, join: false)
      owner = OpenStruct.new(child_scripts: [child])
      guard = instance_double(EO::Engine::Controller::Guard)
      allow(Script).to receive(:start_child).and_return(child)
      children = described_class.new(owner: owner, guard: guard)

      expect(children.start('go2')).to equal(child)
      expect(children.active_travel_child?(child)).to be(true)
      expect(children.active_travel_child?(instance_double('OtherScript'))).to be(false)
    end
  end

  describe EO::Engine::Controller::Runtime do
    it 'marks a completed bounded objective separately from safe return' do
      fixture = runtime_fixture(work: 30, objective: CompletingControllerObjective.new)
      expect(fixture[:runtime].activate_supervised(valid: -> { true })).to be(true)
      result = fixture[:runtime].run
      expect(result[:state]).to eq(:completed)
      expect(result[:reason]).to eq('completed')
      expect(result.dig(:work_result, :state)).to eq(:completed)
      expect(result.dig(:work_result, :reason)).to eq('objective_complete')
      expect(result.dig(:refuge, :returned)).to be(true)
    end

    it 'runs until its work deadline and finishes only after verified refuge return' do
      fixture = runtime_fixture
      expect(fixture[:runtime].activate_supervised(valid: -> { true })).to be(true)
      result = fixture[:runtime].run
      expect(result[:state]).to eq(:stopped)
      expect(result[:reason]).to eq('retreated')
      expect(result.dig(:work_result, :reason)).to eq('operation_work_deadline')
      expect(result[:refuge]).to include(room_id: 1000, phase: 'finished', returned: true,
                                         equipment_restored: true)
      expect(fixture[:engine].stop_reason).to eq(:controller_complete)
    end

    it 'treats an ordinary retreat control as a cooperative return' do
      fixture = runtime_fixture(work: 30)
      expect(fixture[:runtime].request('retreat', valid: -> { true })[:accepted]).to be(true)
      expect(fixture[:runtime].activate_supervised(valid: -> { true })).to be(true)
      result = fixture[:runtime].run
      expect(result.dig(:work_result, :reason)).to eq('manual_retreat')
      expect(result.dig(:refuge, :returned)).to be(true)
    end

    it 'uses the existing rest return after an engine watchdog stop' do
      fixture = runtime_fixture(work: 30)
      fixture[:engine].stop_after_ticks = 2
      expect(fixture[:runtime].activate_supervised(valid: -> { true })).to be(true)
      result = fixture[:runtime].run
      expect(result[:state]).to eq(:stopped)
      expect(result[:reason]).to eq('retreated')
      expect(result.dig(:work_result, :reason)).to eq('engine_stopped:repeated_failures')
      expect(result.dig(:refuge, :returned)).to be(true)
      expect(result.dig(:refuge, :equipment_restored)).to be(true)
    end

    it 'fails closed without return commands when lease authority is lost' do
      fixture = runtime_fixture(work: 30)
      calls = 0
      expect(fixture[:runtime].activate_supervised(valid: -> { calls += 1; calls == 1 })).to be(true)
      result = fixture[:runtime].run
      expect(result[:reason]).to eq('controller_authority_lost')
      expect(result.dig(:refuge, :returned)).to be(false)
      expect(fixture[:rest].phase).to eq(:hunting_prep)
    end

    it 'refuses to claim equipment restoration when hand identity changed' do
      fixture = runtime_fixture
      expect(fixture[:runtime].activate_supervised(valid: -> { true })).to be(true)
      fixture[:state][:hands] = %w[10 12]
      result = fixture[:runtime].run
      expect(result[:reason]).to eq('refuge_equipment_unconfirmed')
      expect(result.dig(:refuge, :equipment_restored)).to be(false)
    end
  end

  # rubocop:enable Lint/ConstantDefinitionInBlock
end
