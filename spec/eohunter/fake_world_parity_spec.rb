require_relative 'engine_helper'
require_relative 'support/fake_world'

# The fake stands in for World in most behavior specs, so a drift between
# the two is a spec that passes against a shape the engine never has.
RSpec.describe 'FakeWorld matches the World it stands in for' do
  it 'takes the same keywords on the readers behaviors actually call' do
    real = EO::Engine::World::RoomView.instance_method(:hazards).parameters
    fake = FakeWorld.instance_method(:hazards).parameters
    expect(fake).to eq(real)

    real_any = EO::Engine::World::RoomView.instance_method(:hazardous?).parameters
    fake_any = FakeWorld.instance_method(:hazardous?).parameters
    expect(fake_any).to eq(real_any)
  end

  it 'filters by family the way the real one does' do
    world = FakeWorld.new
    world.hazard_nouns = %w[vine web]
    expect(world.hazards.size).to eq(2)
    expect(world.hazards(kinds: [:vine]).map(&:noun)).to eq(['vine'])
    expect(world.hazardous?(kinds: [:void])).to be false
    expect(world.hazardous?(kinds: [:web])).to be true
  end
end
