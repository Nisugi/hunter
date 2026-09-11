# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe 'Loadout lifecycle' do
  let(:world) { FakeWorld.new }
  let(:policy) { EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty') }
  let(:adapter) { instance_double(EO::Engine::Loadout::Core, ready_item: nil) }
  let(:loadout) { EO::Engine::Behaviors::Loadout.new(policy: policy, owner: nil, adapter: adapter) }
  let(:rest_policy) { EO::Engine::Rest::Policy.new(resting_room: 10) }
  let(:rest) do
    EO::Engine::Behaviors::Rest.new(policy: rest_policy, stance: ->(_) {},
                                    travel: ->(room) { world.id = room; true })
  end
  let(:wire) do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    body = source[/  def self\.wire\(.*?(?=  def self\.build\()/m]
    Module.new.tap do |mod|
      mod.const_set(:E, EO::Engine)
      mod.define_singleton_method(:msg) { |*| }
      mod.module_eval(body)
    end
  end

  before do
    world.me.encumbrance_pct = 0
    world.me.fxp_pct = 0
    allow(adapter).to receive(:reconcile).and_raise('could not find Item[:weapon]')
  end

  after do
    EO::Engine::Events.reset!
    EO::Engine::Travel.reset!
  end

  it 'uses real Rest to return after one failure, then stops before another hunt' do
    combat = EO::Engine::Behavior.new
    allow(combat).to receive(:wants_control?).and_return(true)
    allow(combat).to receive(:tick)
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout, combat], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: rest_policy, loadout: loadout)

    30.times do
      engine.tick
      break if engine.stopping?
    end

    expect(engine.stop_reason).to eq(:loadout_stuck)
    expect(world.room.id).to eq(10)
    expect(rest.phase).to eq(:resting)
    expect(adapter).to have_received(:reconcile).once
    expect(combat).not_to have_received(:tick)
  end

  it 'reports a follower failure through Orders and uses the leader refuge, not its blank personal setting' do
    member = instance_double(EO::Engine::Group::Member, rooms: { resting: 20 }, orders: [], leader_phase: :hunting)
    follower_policy = EO::Engine::Rest::Policy.new
    orders = EO::Engine::Behaviors::Orders.new(member: member, policy: follower_policy)
    engine = EO::Engine::Engine.new(world: world, behaviors: [orders, loadout], interval: 0)
    wire.wire(engine, rest: orders, rest_policy: follower_policy, member: member, loadout: loadout)

    8.times { engine.tick }
    expect(engine.stopping?).to be false
    expect(orders.forced_reason).to include('could not find')
    expect(adapter).to have_received(:reconcile).once

    world.id = 20
    allow(orders).to receive(:rest_prep_done).and_return(true) # stale completion from an earlier rest
    engine.tick
    expect(engine.stopping?).to be false # the return's equipment/prep cleanup still owns the hands
    EO::Engine::Events.emit(:order, type: :resting_prep)
    engine.tick
    expect(engine.stop_reason).to eq(:loadout_stuck)
    expect(world.room.id).to eq(20)
  end

  [EO::Engine::Behaviors::Loot, EO::Engine::Behaviors::Cleanse, EO::Engine::Behaviors::Flee].each do |klass|
    it "waits for #{klass.name.split('::').last} to release control before restoring hands" do
      owner = klass.allocate
      allow(owner).to receive(:wants_control?).and_return(true, false)
      allow(owner).to receive(:tick)
      engine = EO::Engine::Engine.new(world: world, behaviors: [owner, loadout], interval: 0)
      engine.tick
      expect(adapter).not_to have_received(:reconcile)
      engine.tick
      expect(adapter).to have_received(:reconcile).once
    end
  end

  it 'lets an active go2 finish its destination cleanup without preempting it' do
    scripts = double('travel scripts', start: nil, running?: true, kill: nil)
    trip = EO::Engine::Travel::Trip.new(30, scripts: scripts, unhide: false)
    traveler = EO::Engine::Behavior.new
    allow(traveler).to receive(:priority).and_return(60)
    allow(traveler).to receive(:wants_control?).and_return(true)
    allow(traveler).to receive(:tick) { trip.tick(world) }
    traveler.define_singleton_method(:preempted!) { |_| trip.suspend! }
    trip.tick(world)
    engine = EO::Engine::Engine.new(world: world, behaviors: [loadout, traveler], interval: 0)
    engine.tick
    world.id = 30
    engine.tick
    expect(adapter).not_to have_received(:reconcile)
    expect(scripts).not_to have_received(:kill)
    allow(scripts).to receive(:running?).and_return(false)
    engine.tick
    engine.tick
    expect(adapter).to have_received(:reconcile).once
    expect(scripts).not_to have_received(:kill)
  end
end
