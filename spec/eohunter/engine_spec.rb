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
