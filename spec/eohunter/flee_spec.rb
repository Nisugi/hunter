# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

FleeNpc = Struct.new(:id, :name, :noun, :status, :type, keyword_init: true) unless defined?(FleeNpc)

RSpec.describe EO::Engine::Flee::Predicates do
  def npc(id, name, noun: name.split.last, type: 'aggressive npc')
    FleeNpc.new(id: id.to_s, name: name, noun: noun, status: '', type: type)
  end

  let(:room) { OpenStruct.new(creatures: [], players: [], targets: [], loot: []) }
  let(:targets_policy) { EO::Engine::Targets::Policy.new }
  let(:policy) { EO::Engine::Flee::Policy.new(flee_count: 2, always_flee_from: ['ogre', 'Bob'], clouds: true) }

  before do
    room.define_singleton_method(:hazardous?) { |kinds:| kinds.include?(:cloud) && loot.any? { |o| o.noun == 'cloud' } }
  end

  def reason(**opts) = described_class.reason(room, targets_policy, policy, **opts)

  it 'is nil in a quiet room' do
    room.targets = [npc(1, 'kobold')]
    expect(reason).to be_nil
  end

  it 'flees the profile message and the ambusher first' do
    expect(reason(latched: true)).to eq(:message)
    expect(reason(ambusher: true)).to eq(:ambusher)
  end

  it 'flees a hazard only when its toggle is on' do
    room.loot = [npc(9, 'gas cloud', noun: 'cloud')]
    expect(reason).to eq(:hazard)
    policy.clouds = false
    expect(reason).to be_nil
  end

  it 'flees nothing past always_flee_from in bandit mode, and ignores the ambusher' do
    policy.bandits = true
    room.targets = [npc(1, 'brigand'), npc(2, 'thug'), npc(3, 'robber')]
    expect(reason(ambusher: true)).to be_nil
    expect(reason).to be_nil # three targets over a flee_count of two
    room.creatures = [npc(4, 'ogre')]
    expect(reason).to eq(:always_flee_from)
    room.creatures = []
    room.loot = [npc(9, 'gas cloud', noun: 'cloud')]
    expect(reason).to eq(:hazard)
  end

  it 'flees a creature or a player on always_flee_from' do
    room.creatures = [npc(2, 'cave ogre', noun: 'ogre')]
    expect(reason).to eq(:always_flee_from)
    room.creatures = []
    room.players = [npc(3, 'Bob', noun: 'Bob')]
    expect(reason).to eq(:always_flee_from)
  end

  it 'flees a boon ability on the flee list' do
    policy.boons_flee = ['frenzy']
    boon = npc(4, 'raging kobold', noun: 'kobold', type: 'aggressive npc,boon')
    targets_policy.boon_abilities = ->(c) { c.id == '4' ? ['frenzy'] : nil }
    room.targets = [boon]
    expect(reason).to eq(:boon)
  end

  it 'flees a crowd past flee_count, counting every fightable creature, and one on entry with lone_targets_only' do
    room.targets = [npc(1, 'kobold'), npc(2, 'kobold'), npc(3, 'severed arm', noun: 'arm')]
    expect(reason).to be_nil
    room.targets << npc(4, 'kobold')
    expect(reason).to eq(:crowd)
    room.targets = [npc(1, 'kobold'), npc(2, 'kobold')]
    policy.lone_targets_only = true
    expect(reason(just_entered: true)).to eq(:crowd)
    expect(reason(just_entered: false)).to be_nil
  end
end

RSpec.describe EO::Engine::Wander::Walker do
  let(:world) { OpenStruct.new(room: OpenStruct.new(id: 1)) }

  before do
    graph = { 1 => { 2 => 'north', 3 => 'east', 9 => 'south' } }
    world.define_singleton_method(:exits_from) { |id| graph.fetch(id, {}) }
  end

  it 'never steps into a boundary room' do
    walker = described_class.new(boundaries: [9])
    steps = 20.times.map { walker.next_step(world).first }
    expect(steps).not_to include(9)
  end

  it 'prefers rooms not walked lately, then the least recent' do
    walker = described_class.new(boundaries: [9])
    first, = walker.next_step(world)
    second, = walker.next_step(world)
    expect([first, second].sort).to eq([2, 3])
    third, = walker.next_step(world)
    expect(third).to eq(first)
  end

  it 'is nil with no usable exit' do
    expect(described_class.new(boundaries: [2, 3, 9]).next_step(world)).to be_nil
  end
end

RSpec.describe EO::Engine::Actions::Move do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false) }
  let(:room) { OpenStruct.new(count: 7) }
  let(:world) { OpenStruct.new(me: me, room: room) }

  def scripted(action, replies, on_send: nil)
    queue = []
    allow(action).to receive(:game_put) { |_cmd| on_send&.call; queue.concat(replies.shift || []) }
    allow(action).to receive(:clear_lines) { queue.clear }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |l| queue.unshift(l) }
    allow(action).to receive(:sleep)
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  it 'sends a direction and confirms on the room counter' do
    action = scripted(described_class.new(world, way: 'north'), [['[Kobold Village, Path]']], on_send: -> { room.count = 8 })
    expect(action.call).to be_success
  end

  it 'times out when the room never changes' do
    action = scripted(described_class.new(world, way: 'north', timeout: 0.05), [["You can't go there."]])
    expect(action.call.reason).to eq(:state_unchanged)
  end

  it 'calls a proc way' do
    called = false
    action = scripted(described_class.new(world, way: -> { called = true; room.count = 8 }), [])
    expect(action.call).to be_success
    expect(called).to be true
  end
end

RSpec.describe EO::Engine::Actions::Escape do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false) }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(id: '1', name: 'a steel dagger', type: 'weapon')) }
  let(:room) { OpenStruct.new(title: 'The Belly of the Beast', count: 1, exits: []) }
  let(:world) { OpenStruct.new(me: me, room: room, hands: hands) }

  it 'knows the three rooms by title' do
    expect(described_class.kind_for('[The Belly of the Beast]')).to eq(:worm)
    expect(described_class.kind_for('[Ooze, Innards]')).to eq(:ooze)
    expect(described_class.kind_for('[Temporal Rift]')).to eq(:rift)
    expect(described_class.kind_for('[Kobold Village]')).to be_nil
  end

  it 'is :not_trapped elsewhere' do
    room.title = '[Kobold Village]'
    expect(described_class.new(world).call.reason).to eq(:not_trapped)
  end

  it 'attacks the wall with the dagger in hand until the room changes' do
    action = described_class.new(world)
    swings = 0
    allow(action).to receive(:send_and_match) do |_cmd, _rx, **|
      swings += 1
      room.title = '[Kobold Village]' if swings == 3
      EO::Engine::Actions::Result.new(status: :success, line: 'You swing a steel dagger at the wall!')
    end
    allow(action).to receive(:sleep)
    expect(action.call).to be_success
    expect(swings).to eq(3)
  end

  it 'uses a blunt weapon in the ooze and stops on "What were you referring to"' do
    room.title = '[Ooze, Innards]'
    hands.right = OpenStruct.new(id: '2', name: 'an iron mace', type: 'weapon')
    action = described_class.new(world)
    sent = []
    allow(action).to receive(:send_and_match) do |cmd, _rx, **|
      sent << cmd
      EO::Engine::Actions::Result.new(status: :success, line: 'What were you referring to?')
    end
    result = action.call
    expect(sent).to eq(['kill organ'])
    expect(result.reason).to eq(:still_trapped)
  end

  it 'waits it out with no weapon' do
    hands.right = OpenStruct.new(id: nil, name: 'Empty', type: '')
    action = described_class.new(world)
    allow(action).to receive(:escape_candidates).and_return([])
    allow(action).to receive(:send_through_ladder).and_return('You stow everything.')
    allow(action).to receive(:sleep) { room.title = '[Kobold Village]' }
    result = action.call
    expect(result).to be_success
    expect(result.reason).to eq(:no_weapon)
  end
end

RSpec.describe EO::Engine::Watch do
  after { described_class.clear!; EO::Engine::Events.reset! }

  it 'emits the rule event with the match data and the raw line, and leaves the line alone' do
    seen = []
    EO::Engine::Events.on(:ambusher) { |e| seen << e.data }
    described_class.on(/(?<noun>\w+) leaps from hiding/, :ambusher) { |m| { noun: m[:noun] } }
    line = 'A kobold leaps from hiding to attack!'
    expect(described_class.hook_proc.call(line)).to equal(line)
    expect(seen).to eq([{ noun: 'kobold', raw: line }])
  end

  it 'isolates a rule whose data block raises' do
    errors = []
    EO::Engine::Events.on(:watch_error) { |e| errors << e.data[:event] }
    described_class.on(/boom/, :boom) { |_m| raise 'bad' }
    described_class.process('boom')
    expect(errors).to eq([:boom])
  end
end

RSpec.describe EO::Engine::Behaviors::Flee do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false) }
  let(:room) { OpenStruct.new(id: 1, count: 1, creatures: [], players: [], targets: [], loot: []) }
  let(:world) { OpenStruct.new(me: me, room: room) }
  let(:policy) { EO::Engine::Flee::Policy.new(flee_count: 1, boundaries: [9]) }
  let(:flee) { described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new) }

  before do
    room.define_singleton_method(:hazardous?) { |**| false }
    world.define_singleton_method(:exits_from) { |_id| { 2 => 'north', 9 => 'south' } }
  end

  after { EO::Engine::Events.reset!; EO::Engine::Watch.clear! }

  it 'does not want control in a quiet room' do
    expect(flee.wants_control?(world)).to be false
  end

  it 'latches the flee message from the watch and clears it on bolt' do
    flee
    EO::Engine::Events.emit(:flee_message, raw: 'The ground trembles')
    expect(flee.wants_control?(world)).to be true
    expect(flee.reason).to eq(:message)
    EO::Engine::Events.emit(:bolted)
    expect(flee.wants_control?(world)).to be false
  end

  it 'ignores an ambusher who is a group member' do
    grouped = described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, group_nouns: -> { ['Bob'] })
    EO::Engine::Events.emit(:ambusher, noun: 'Bob')
    expect(grouped.wants_control?(world)).to be false
    EO::Engine::Events.emit(:ambusher, noun: 'kobold')
    expect(grouped.wants_control?(world)).to be true
  end

  it 'steps out of the room, never into a boundary, and clears the latch on arrival' do
    EO::Engine::Events.emit(:flee_message, raw: 'x')
    flee.wants_control?(world)
    move = instance_double(EO::Engine::Actions::Move, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Move).to receive(:new).with(world, way: 'north').and_return(move)
    expect(flee.tick(world)).to be_success
    room.id = 2
    expect(flee.wants_control?(world)).to be false
  end
end
