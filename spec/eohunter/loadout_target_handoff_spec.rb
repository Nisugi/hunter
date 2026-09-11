# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'Loadout target handoff' do
  let(:staff) { OpenStruct.new(id: '100', name: 'staff') }
  let(:maul) { OpenStruct.new(id: '101', name: 'maul') }
  let(:bow) { OpenStruct.new(id: '102', name: 'bow') }
  let(:orc) { OpenStruct.new(id: '1', name: 'orc', noun: 'orc', status: '', type: 'aggressive npc') }
  let(:kobold) { OpenStruct.new(id: '2', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc') }
  let(:world) do
    OpenStruct.new(me: OpenStruct.new(dead?: false, muckled?: false, current_target_id: '1', in_rt?: false, in_cast_rt?: false),
                   room: OpenStruct.new(id: 1, targets: [orc], players: []),
                   hands: OpenStruct.new(right: staff, left: nil), claim_mine?: true, foreign_disks: [])
  end
  let(:combat_policy) do
    EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack'], 'b' => ['wield maul', 'attack'] }, priority: true)
  end
  let(:targets_policy) { EO::Engine::Targets::Policy.new(wanted: { 'kobold' => 'a', 'orc' => 'b' }) }
  let(:engage) do
    EO::Engine::Behaviors::Engage.new(policy: combat_policy, targets_policy: targets_policy, stance: ->(_) { true })
  end
  let(:policy) { EO::Engine::Loadout::Policy.new(right: 'ready:weapon') }
  let(:selection) { nil }
  let(:adapter) { instance_double(EO::Engine::Loadout::Core) }
  let(:loadout) do
    EO::Engine::Behaviors::Loadout.new(policy: policy, selection: selection, owner: engage, adapter: adapter)
  end
  let(:engine) { EO::Engine::Engine.new(world: world, behaviors: [loadout, engage], interval: 0) }
  let(:attacks) { [] }

  before do
    allow(adapter).to receive(:ready_item) { |slot| { weapon: staff, ranged_weapon: bow }[slot] }
    allow(adapter).to receive(:reconcile) do |right:, left:|
      world.hands.right = { weapon: staff, ranged_weapon: bow }[right] unless right == :keep
      world.hands.left = nil unless left == :keep
    end
    allow(engage).to receive(:run_line) do |_world, line|
      if line.text == 'wield maul'
        world.hands.right = maul
      else
        attacks << [engage.target.id, world.hands.right&.id]
      end
      EO::Engine::Actions::Result.new(status: :success)
    end
    allow(engage).to receive(:ensure_targeted).and_return(nil)
  end

  after do
    EO::Engine::Events.reset!
    EO::Engine::Travel.reset!
  end

  it 'restores the baseline before taking a higher-priority target while the old target lives' do
    engine.tick
    world.room.targets << kobold
    engine.tick

    expect(attacks).to be_empty
    expect(world.hands.right).to eq(staff)
    engine.tick
    expect(attacks).to eq([['2', '100']])
  end

  it 'preserves an intentional weapon swap for the same target and restores after despawn' do
    engine.tick
    engine.tick
    expect(attacks).to eq([['1', '101']])
    expect(adapter).not_to have_received(:reconcile)

    world.room.targets.clear
    engine.tick
    expect(world.hands.right).to eq(staff)
    expect(adapter).to have_received(:reconcile).once
  end

  it 'refuses an obsolete candidate without moving equipment' do
    world.room.targets = [kobold]

    expect(loadout.prepare_target(world, orc).reason).to eq(:loadout_target_changed)
    expect(adapter).not_to have_received(:reconcile)
  end

  context 'when all hands are unmanaged' do
    let(:policy) { EO::Engine::Loadout::Policy.new }

    it 'leaves a routine weapon in place across target changes' do
      engine.tick
      world.room.targets << kobold
      engine.tick

      expect(attacks).to eq([['2', '101']])
      expect(adapter).not_to have_received(:reconcile)
    end
  end

  context 'with target-specific selection' do
    let(:selection) do
      EO::Engine::Loadout::Selection.new(default: policy, sets: { 'ranged' => { 'right' => 'ready:ranged_weapon' } },
                                         rules: [{ 'set' => 'ranged', 'target' => 'kobold' }])
    end

    it 'establishes the selected set before a new target and defaults after the encounter' do
      engine.tick
      world.room.targets << kobold
      engine.tick
      expect(world.hands.right).to eq(bow)
      expect(attacks).to be_empty
      engine.tick
      expect(attacks).to eq([['2', '102']])

      world.room.targets.clear
      engine.tick
      expect(world.hands.right).to eq(staff)
    end

    it 'prepares the default for departure even when a target selects another set' do
      world.room.targets = [kobold]
      world.hands.right = bow

      expect(loadout.prepare(world)).to be_success
      expect(world.hands.right).to eq(staff)
    end

    it 'rechecks the candidate after a target dies during the Stash action' do
      world.room.targets = [kobold]
      allow(adapter).to receive(:reconcile) do |right:, **|
        world.hands.right = right == :ranged_weapon ? bow : staff
        world.room.targets = [orc] if right == :ranged_weapon
      end

      engine.tick
      expect(world.hands.right).to eq(bow)
      engine.tick
      expect(world.hands.right).to eq(staff)
      expect(attacks).to be_empty
      expect(engage.target).to be_nil
    end

    it 'checks a newly selected target at action time after arbitration saw the old target' do
      engine.tick
      expect(loadout.wants_control?(world)).to be false
      world.room.targets << kobold

      result = engage.tick(world)

      expect(result).to be_success
      expect(world.hands.right).to eq(bow)
      expect(attacks).to be_empty
      expect(engage.target).to eq(orc)
    end

    it 'defers when the selected creature changes after the action-time hand check' do
      engine.tick
      allow(engage).to receive(:assess_boons) { world.room.targets << kobold; nil }

      result = engage.tick(world)

      expect(result.reason).to eq(:loadout_target_changed)
      expect(attacks).to be_empty
      expect(engage.target).to eq(orc)
      engine.tick
      expect(world.hands.right).to eq(bow)
    end

    context 'with an unmanaged default' do
      let(:policy) { EO::Engine::Loadout::Policy.new }

      it 'still enforces managed named selections' do
        world.room.targets = [kobold]
        engine.tick
        expect(world.hands.right).to eq(bow)
        expect(attacks).to be_empty
        engine.tick
        expect(attacks).to eq([['2', '102']])
      end

      it 'retains a named-set failure through default preparation' do
        world.room.targets = [kobold]
        allow(adapter).to receive(:reconcile).and_raise('could not find Item[:ranged_weapon]')
        engine.tick

        expect(loadout).to be_stuck
        expect(loadout.prepare(world)).to be_failed
        expect(attacks).to be_empty
      end
    end
  end

  context 'as a follower' do
    let(:member) { double('Member', leader_name: 'Leader', leader_target: { id: '1' }) }
    let(:combat_policy) { EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack'], 'b' => ['wield maul', 'attack'] }) }
    let(:engage) do
      EO::Engine::Behaviors::Assist.new(member: member, policy: combat_policy, targets_policy: targets_policy, stance: ->(_) { true })
    end

    it 'hands off when the leader changes target while the previous creature lives' do
      world.room.players = [OpenStruct.new(noun: 'Leader')]
      world.room.targets << kobold
      engage.attack!
      engine.tick
      allow(member).to receive(:leader_target).and_return(id: '2')
      engine.tick

      expect(world.hands.right).to eq(staff)
      expect(attacks).to be_empty
      engine.tick
      expect(attacks).to eq([['2', '100']])
    end
  end

  context 'with recovery interruption wiring' do
    let(:wire) do
      source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
      body = source[/  def self\.wire\(.*?(?=  def self\.build\()/m]
      Module.new.tap do |mod|
        mod.const_set(:E, EO::Engine)
        mod.define_singleton_method(:msg) { |*| }
        mod.module_eval(body)
      end
    end
    let(:rest) { EO::Engine::Behaviors::Rest.new(policy: EO::Engine::Rest::Policy.new(resting_room: 10)) }
    let(:survival) { double('Survival', wants_control?: false) }

    before do
      wire.wire(engine, rest: rest, rest_policy: EO::Engine::Rest::Policy.new(resting_room: 10),
                        loadout: loadout, engage: engage, survival: survival)
      engage.retarget(orc)
    end

    [:pause, :survival].each do |interrupt|
      it "interrupts a managed throw when #{interrupt} takes priority" do
        action = instance_double(EO::Engine::Actions::Attack)
        allow(EO::Engine::Actions::Attack).to receive(:new).and_return(action)
        allow(action).to receive(:call) do
          world.hands.right = nil
          if interrupt == :pause
            engine.pause!
          else
            allow(survival).to receive(:wants_control?).with(world).and_return(true)
          end
          EO::Engine::Actions::Result.new(status: :success)
        end
        expect_any_instance_of(EO::Engine::Actions::RecoverHurl).not_to receive(:send_and_match)
        line = EO::Engine::Engage::Routine.parse(['hurl target']).first

        result = engage.dispatch(world, 'hurl #1', line)

        expect(result.reason).to eq(:interrupted)
        expect(loadout).to be_stuck
      end
    end
  end
end
