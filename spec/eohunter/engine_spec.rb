# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe EO::Engine::Engine do
  after { EO::Engine::Events.reset! }

  let(:world) { FakeWorld.new }

  def behavior(priority:, wants:, result: nil, &block)
    b = EO::Engine::Behavior.new
    allow(b).to receive_messages(priority: priority, wants_control?: wants)
    allow(b).to receive(:tick) do |_w|
      block&.call
      result
    end
    b
  end

  it 'gives control to the highest-priority (lowest number) willing behavior' do
    order = []
    urgent = behavior(priority: 0, wants: true) { order << :urgent }
    casual = behavior(priority: 50, wants: true) { order << :casual }
    engine = described_class.new(world: world, behaviors: [casual, urgent], interval: 0)
    engine.tick
    expect(order).to eq([:urgent])
  end

  it 'falls through to lower priority when higher declines' do
    order = []
    urgent = behavior(priority: 0, wants: false) { order << :urgent }
    casual = behavior(priority: 50, wants: true) { order << :casual }
    engine = described_class.new(world: world, behaviors: [urgent, casual], interval: 0)
    engine.tick
    expect(order).to eq([:casual])
  end

  it 'trips the watchdog after N consecutive failed actions' do
    failing = behavior(priority: 0, wants: true,
                       result: EO::Engine::Actions::Result.new(status: :timeout))
    tripped = []
    EO::Engine::Events.on(:watchdog_tripped) { |e| tripped << e.data }
    engine = described_class.new(world: world, behaviors: [failing],
                                 interval: 0, max_consecutive_failures: 3)
    3.times { engine.tick }
    expect(engine.stopping?).to be(true)
    expect(engine.stop_reason).to eq(:repeated_failures)
    expect(tripped.first[:count]).to eq(3)
  end

  it 'resets the failure count on success' do
    results = [
      EO::Engine::Actions::Result.new(status: :timeout),
      EO::Engine::Actions::Result.new(status: :timeout),
      EO::Engine::Actions::Result.new(status: :success),
      EO::Engine::Actions::Result.new(status: :timeout)
    ]
    flaky = behavior(priority: 0, wants: true)
    allow(flaky).to receive(:tick) { results.shift }
    engine = described_class.new(world: world, behaviors: [flaky],
                                 interval: 0, max_consecutive_failures: 3)
    4.times { engine.tick }
    expect(engine.stopping?).to be(false)
  end

  it 'does not count deliberately skipped routine lines as failed actions' do
    skipped = behavior(
      priority: 0,
      wants: true,
      result: EO::Engine::Actions::Result.new(status: :skipped, reason: :condition)
    )
    engine = described_class.new(world: world, behaviors: [skipped],
                                 interval: 0, max_consecutive_failures: 3)
    5.times { engine.tick }
    expect(engine.stopping?).to be(false)
  end

  it 'stops on engine errors instead of grinding' do
    exploder = behavior(priority: 0, wants: true)
    allow(exploder).to receive(:tick).and_raise('unexpected')
    errors = []
    EO::Engine::Events.on(:engine_error) { |e| errors << e.data }
    engine = described_class.new(world: world, behaviors: [exploder], interval: 0)
    engine.tick
    expect(engine.stop_reason).to eq(:engine_error)
    expect(errors.first[:message]).to eq('unexpected')
  end

  it 'tells the behavior it preempts, once, and again on idle and pause' do
    log = []
    urgent = behavior(priority: 0, wants: false)
    walker = behavior(priority: 50, wants: true)
    walker.define_singleton_method(:preempted!) { |_w| log << :suspended }
    EO::Engine::Events.on(:preempted) { |e| log << [e.data[:from], e.data[:to]] }
    engine = described_class.new(world: world, behaviors: [urgent, walker], interval: 0)
    2.times { engine.tick }
    expect(log).to be_empty
    allow(urgent).to receive(:wants_control?).and_return(true)
    2.times { engine.tick }
    expect(log).to eq([:suspended, ['behavior', 'behavior']])
    allow(urgent).to receive(:wants_control?).and_return(false)
    engine.tick # the walker again
    allow(walker).to receive(:wants_control?).and_return(false)
    engine.tick # idle
    expect(log.last).to eq(['behavior', nil])
    allow(walker).to receive(:wants_control?).and_return(true)
    engine.tick
    engine.pause!
    engine.tick
    expect(log.count(:suspended)).to eq(3)
  end

  it 'acts on nothing after a tick callback stops it' do
    ticked = []
    b = behavior(priority: 0, wants: true) { ticked << :acted }
    engine = described_class.new(world: world, behaviors: [b], interval: 0)
    engine.on_tick { engine.stop!(:leader_lost) }
    engine.tick
    expect(ticked).to be_empty
    expect(engine.stop_reason).to eq(:leader_lost)
  end

  it 'announces each new room before choosing a behavior, so a waiting fight sees a fresh room' do
    seen = []
    EO::Engine::Events.on(:entered_room) { |e| seen << [e.data[:room], :event] }
    fight = behavior(priority: 50, wants: true) { seen << :fight }
    engine = described_class.new(world: world, behaviors: [fight], interval: 0)
    engine.tick
    world.id = 2
    engine.tick
    engine.tick
    expect(seen).to eq([[1, :event], :fight, [2, :event], :fight, :fight])
  end

  it 'run loops until stopped and reports the reason' do
    counter = 0
    b = behavior(priority: 0, wants: true)
    engine = described_class.new(world: world, behaviors: [b], interval: 0)
    allow(b).to receive(:tick) do
      counter += 1
      engine.stop!(:goal_reached) if counter >= 3
      EO::Engine::Actions::Result.new(status: :success)
    end
    expect(engine.run).to eq(:goal_reached)
    expect(counter).to eq(3)
  end
end
