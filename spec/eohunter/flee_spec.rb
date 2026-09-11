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

  it 'flees the profile message first' do
    expect(reason(latched: true)).to eq(:message)
  end

  it 'flees a hazard only when its toggle is on' do
    room.loot = [npc(9, 'gas cloud', noun: 'cloud')]
    expect(reason).to eq(:hazard)
    policy.clouds = false
    expect(reason).to be_nil
  end

  it 'flees nothing past always_flee_from in bandit mode' do
    policy.bandits = true
    room.targets = [npc(1, 'brigand'), npc(2, 'thug'), npc(3, 'robber')]
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
    room.targets = [npc(1, 'kobold'), npc(2, 'kobold'), npc(3, 'shadowy haze', noun: 'haze')]
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
    allow(action).to receive(:game_send) { |_cmd| on_send&.call; queue.concat(replies.shift || []); queue.first || :no_response }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |l| queue.unshift(l) }
    allow(action).to receive(:sleep)
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  it "sends a String way through Lich's move and reads its three answers" do
    moved = []
    action = described_class.new(world, way: 'north', timeout: 0.05)
    allow(action).to receive(:game_move) { |way| moved << way; true }
    expect(action.call).to be_success
    expect(moved).to eq(['north'])

    allow(action).to receive(:game_move).and_return(false)
    expect(action.call.reason).to eq(:no_way)
    allow(action).to receive(:game_move).and_return(nil)
    expect(action.call.reason).to eq(:not_allowed)
  end

  # game_move is the send seam: it reaches the game through Lich's move
  # rather than the ladder, so it carries the stamp itself. Stubbing
  # game_move (as the example above does) steps over that, so this one
  # stubs Lich's move underneath it.
  it 'stamps a room step as acted, so the fire budget can see it' do
    action = described_class.new(world, way: 'north', timeout: 0.05)
    allow(action).to receive(:move) { room.count = 8; true }
    allow(action).to receive(:sleep)
    result = action.call
    expect(result).to be_success
    expect(result).to be_acted
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

  # Lich's WeaponStats catalogue, as the action reads it
  before { allow_any_instance_of(described_class).to receive(:escape_weapon_names) { |_a, kind| kind == :worm ? ['dagger', 'sgian dubh'] : ['mace', 'war club'] } }

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

  # bigshot drags the escape weapon back to its container and calls
  # fill_hands once it is out (9670); on the no-weapon path it stows both
  # and fill_hands too (9638). Without this the hunt carried on with the
  # boot dagger in hand and the real weapon in a sack.
  #
  # These drive Lich's real push/pop contract rather than counting calls:
  # Stash keeps three restore stacks and each equip_hands flavour pops
  # exactly one (stash.rb 259-261, 574-586), so asserting only that
  # equip_hands was called cannot tell a correct restore from one that pops
  # an empty stack and raises into our rescue.
  def stash_double(hand_state)
    stacks = { both: [], right: [], left: [] }
    stash = class_double('Lich::Stash').as_stubbed_const
    allow(stash).to receive(:stash_hands) do |**kw|
      which = kw[:both] ? :both : (kw[:right] ? :right : :left)
      held = hand_state[:right]
      hand_state[:right] = nil
      stacks[which].push(-> { hand_state[:right] = held })
    end
    allow(stash).to receive(:equip_hands) do |**kw|
      which = kw[:both] ? :both : (kw[:right] ? :right : :left)
      # Lich pops and iterates; an empty stack raises, as it does in Lich
      stacks[which].pop.call
    end
    allow(stash).to receive(:wield) do |item, **kw|
      which = kw[:hand] || :right
      held = hand_state[:right]
      stacks[which].push(-> { hand_state[:right] = held })
      hand_state[:right] = item
    end
    [stash, stacks]
  end

  it 'puts the escape weapon away and takes the real one back' do
    state = { right: OpenStruct.new(id: '1', name: 'a claidhmore', type: 'weapon') }
    _stash, stacks = stash_double(state)
    hands.right = OpenStruct.new(id: nil, name: 'Empty', type: '')
    dagger = OpenStruct.new(id: '9', name: 'a boot dagger', type: 'weapon')

    action = described_class.new(world)
    allow(action).to receive(:escape_candidates).and_return([dagger])
    allow(action).to receive(:weapon_in_hand) { hands.right.id ? hands.right : nil }
    allow(action).to receive(:wield) { |i| ::Lich::Stash.wield(i, hand: :right); hands.right = i }
    allow(action).to receive(:send_and_match) do |_cmd, _rx, **|
      room.title = '[Kobold Village]'
      EO::Engine::Actions::Result.new(status: :success, line: 'You swing!')
    end

    expect(action.call).to be_success
    # the original weapon is back in hand, and no restore frame is orphaned
    expect(state[:right].name).to eq('a claidhmore')
    expect(stacks.values.map(&:size)).to eq([0, 0, 0])
  end

  it 'leaves the hands alone when the weapon was already in them' do
    state = { right: nil }
    stash, = stash_double(state)
    action = described_class.new(world) # hands.right is already a dagger
    allow(action).to receive(:send_and_match) do |_cmd, _rx, **|
      room.title = '[Kobold Village]'
      EO::Engine::Actions::Result.new(status: :success, line: 'You swing!')
    end
    expect(action.call).to be_success
    expect(stash).not_to have_received(:stash_hands)
    expect(stash).not_to have_received(:equip_hands)
  end

  it 'does not refill while still trapped' do
    state = { right: nil }
    stash, = stash_double(state)
    action = described_class.new(world)
    allow(action).to receive(:send_and_match) do |_cmd, _rx, **|
      EO::Engine::Actions::Result.new(status: :success, line: 'You swing!')
    end
    expect(action.call.reason).to eq(:still_trapped)
    expect(stash).not_to have_received(:equip_hands)
  end

  it 'waits it out with no weapon, remembering what it stowed' do
    state = { right: OpenStruct.new(id: '1', name: 'a claidhmore', type: 'weapon') }
    _stash, stacks = stash_double(state)
    hands.right = OpenStruct.new(id: nil, name: 'Empty', type: '')
    action = described_class.new(world)
    allow(action).to receive(:escape_candidates).and_return([])
    allow(action).to receive(:sleep) { room.title = '[Kobold Village]' }
    result = action.call
    expect(result).to be_success
    expect(result.reason).to eq(:no_weapon)
    # through Stash, so there is something to bring back: a raw 'stow all'
    # empties the hands with no restore frame, which is the state bigshot's
    # own fill_hands finds nothing for (9638)
    expect(state[:right].name).to eq('a claidhmore')
    expect(stacks.values.map(&:size)).to eq([0, 0, 0])
  end

  it 'falls back to a plain stow when Stash is not there' do
    hide_const('Lich::Stash')
    hands.right = OpenStruct.new(id: nil, name: 'Empty', type: '')
    action = described_class.new(world)
    sent = []
    allow(action).to receive(:escape_candidates).and_return([])
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; 'ok' }
    allow(action).to receive(:sleep) { room.title = '[Kobold Village]' }
    expect(action.call).to be_success
    expect(sent).to eq(['stow all'])
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

  after { EO::Engine::Events.reset!; EO::Engine::Watch.clear!; EO::Engine::Travel.reset! }

  it 'does not want control in a quiet room' do
    expect(flee.wants_control?(world)).to be false
  end

  it 'does not seize movement from a supervised go2 trip in a hazardous transit room' do
    policy.clouds = true
    scripts = Class.new do
      def initialize = @running = []
      def start(name, _args) = @running << name
      def running?(name) = @running.include?(name)
      def kill(name) = @running.delete(name)
      def finish!(name) = @running.delete(name)
    end.new
    trip = EO::Engine::Travel::Trip.new(200, scripts: scripts)
    trip.tick(world)
    room.define_singleton_method(:hazardous?) { |**| true }

    expect(EO::Engine::Travel.active).to equal(trip)
    expect(flee.wants_control?(world)).to be false
    expect(scripts.running?('go2')).to be true
  end

  it 'takes control once a supervised trip ends in a hazardous room' do
    policy.clouds = true
    scripts = Class.new do
      def initialize = @running = []
      def start(name, _args) = @running << name
      def running?(name) = @running.include?(name)
      def kill(name) = @running.delete(name)
      def finish!(name) = @running.delete(name)
    end.new
    trip = EO::Engine::Travel::Trip.new(200, scripts: scripts)
    trip.tick(world)
    scripts.finish!('go2')
    trip.tick(world)
    room.define_singleton_method(:hazardous?) { |**| true }

    expect(EO::Engine::Travel.underway?).to be false
    expect(flee.wants_control?(world)).to be true
    expect(flee.reason).to eq(:hazard)
  end

  it 'latches the flee message from the watch and clears it on bolt' do
    flee
    EO::Engine::Events.emit(:flee_message, raw: 'The ground trembles')
    expect(flee.wants_control?(world)).to be true
    expect(flee.reason).to eq(:message)
    EO::Engine::Events.emit(:bolted)
    expect(flee.wants_control?(world)).to be false
  end

  # bigshot never leaves a room over $ambusher_here: attack_break (7750)
  # stops the attack cycle, reset_variables (8836) clears the latch on the
  # next room, and the now-visible ambusher is handed back as the target
  # in the same room. As a flee reason it abandoned a fight bigshot
  # finishes, and could pin the engine in permanent flee when the step
  # could not happen.
  it 'does not flee an ambusher: bigshot re-targets it in place' do
    grouped = described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, group_nouns: -> { ['Bob'] })
    EO::Engine::Events.emit(:ambusher, noun: 'kobold')
    expect(grouped.wants_control?(world)).to be false
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
