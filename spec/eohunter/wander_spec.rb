# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Wander::Area do
  let(:world) { OpenStruct.new }

  before do
    graph = { 1 => { 2 => 'n', 9 => 's' }, 2 => { 1 => 's', 3 => 'e' }, 3 => { 2 => 'w', 4 => 'e' }, 4 => { 3 => 'w' }, 9 => { 1 => 'n', 10 => 's' } }
    world.define_singleton_method(:exits_from) { |id| graph.fetch(id, {}) }
    world.define_singleton_method(:room_location) { |id| id == 4 ? 'Town' : 'Forest' }
  end

  it 'walks every room reachable without crossing a boundary' do
    area = described_class.new(start: 1, boundaries: [9]).build(world)
    expect(area.rooms.sort).to eq([1, 2, 3, 4])
    expect(area.include?(10)).to be false
    expect(area.too_big?).to be false
  end

  it 'flags an area past the cap and records where the location changed' do
    area = described_class.new(start: 1, boundaries: [], cap: 3).build(world)
    expect(area.too_big?).to be true
    expect(described_class.new(start: 1, boundaries: [9]).build(world).location_changes).to eq([{ id: 4, location: 'Town' }])
  end
end

RSpec.describe EO::Engine::Wander::Predicates do
  let(:world) { OpenStruct.new(claim_mine?: true, foreign_disks: [], room: OpenStruct.new(targets: [])) }
  let(:policy) { EO::Engine::Wander::Policy.new }

  it 'is ours only with the claim and no foreign disk, unless disks are ignored' do
    expect(described_class.claim_ours?(world, policy)).to be true
    world[:foreign_disks] = [OpenStruct.new(name: 'a disk')]
    expect(described_class.claim_ours?(world, policy)).to be false
    policy.ignore_disks = true
    expect(described_class.claim_ours?(world, policy)).to be true
    world[:claim_mine?] = false
    expect(described_class.claim_ours?(world, policy)).to be false
  end

  it 'has a fight only when the room is ours and a wanted creature is here' do
    tp = EO::Engine::Targets::Policy.new
    expect(described_class.fight_here?(world, tp, policy)).to be false
    world.room.targets = [OpenStruct.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc')]
    expect(described_class.fight_here?(world, tp, policy)).to be true
    world[:claim_mine?] = false
    expect(described_class.fight_here?(world, tp, policy)).to be false
  end
end

RSpec.describe EO::Engine::Actions::Hide do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, hidden?: false, able_to_sneak?: true) }
  let(:world) { OpenStruct.new(me: me) }
  let(:sent) { [] }

  def hide(**opts)
    action = described_class.new(world, timeout: 0.05, **opts)
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; 'You attempt to blend with the surroundings.' }
    allow(action).to receive(:sleep)
    action
  end

  it 'sends HIDE until hidden' do
    sends = sent
    allow(me).to receive(:hidden?) { sends.size >= 2 }
    expect(hide.call).to be_success
    expect(sent).to eq(['hide', 'hide'])
  end

  it 'gives up after the attempts' do
    expect(hide(attempts: 2).call.reason).to eq(:not_hidden)
    expect(sent.size).to eq(2)
  end

  it 'does nothing when already hidden' do
    me[:hidden?] = true
    expect(hide.call.reason).to eq(:already_hidden)
  end

  it "refuses when Lich's Injured says the legs cannot sneak" do
    me[:able_to_sneak?] = false
    expect(hide.call.reason).to eq(:too_injured)
    expect(sent).to be_empty
  end
end

RSpec.describe EO::Engine::Behaviors::Wander do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, hidden?: true) }
  let(:room) { OpenStruct.new(id: 1, count: 1, targets: []) }
  let(:world) { OpenStruct.new(me: me, room: room, claim_mine?: true, foreign_disks: []) }
  let(:policy) { EO::Engine::Wander::Policy.new(hunting_room: 1, boundaries: [9], wander_wait: 1, wander_stance: 'defensive') }
  let(:now) { [Time.at(100)] }
  let(:clock) { Class.new { def initialize(box) = @box = box; def now = @box.first }.new(now) }
  let(:stances) { [] }
  let(:trips) { [] }
  let(:moves) { [] }
  let(:state) { EO::Engine::Engage::State.new }
  let(:wander) do
    described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, clock: clock,
                        stance: ->(s) { stances << s; true }, travel: ->(r) { trips << r; true }, state: state)
  end

  before do
    world.define_singleton_method(:exits_from) { |_id| { 2 => 'north', 9 => 'south' } }
    allow(EO::Engine::Actions::Move).to receive(:new) do |_w, way:|
      moves << way
      instance_double(EO::Engine::Actions::Move, call: EO::Engine::Actions::Result.new(status: :success))
    end
  end

  after { EO::Engine::Events.reset! }

  it 'wants control with nothing to fight, not while a wanted creature is here in our room' do
    expect(wander.wants_control?(world)).to be true
    room.targets = [OpenStruct.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc')]
    expect(wander.wants_control?(world)).to be false
    world[:claim_mine?] = false
    expect(wander.wants_control?(world)).to be true
  end

  it 'gives our room wander_wait, then drops stance once and steps out, never into a boundary' do
    wander.wants_control?(world)
    expect(wander.tick(world)).to be_nil
    now[0] = Time.at(101)
    expect(wander.tick(world)).to be_success
    expect(stances).to eq(['defensive'])
    expect(moves).to eq(['north'])
    expect(trips).to be_empty
  end

  it 'leaves a room that is not ours at once' do
    world[:claim_mine?] = false
    wander.wants_control?(world)
    expect(wander.tick(world)).to be_success
    expect(moves).to eq(['north'])
  end

  it 'leaves a temporarily combat-blocked room before waiting on hidden creatures' do
    room.targets = [OpenStruct.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc')]
    world[:hiders?] = true
    world[:hidden_target_ids] = ['2']
    state.combat_blocked_room = room.id

    expect(wander.wants_control?(world)).to be(true)
    expect(wander.tick(world)).to be_success
    expect(stances).to eq(['defensive'])
    expect(moves).to eq(['north'])
  end

  it 'hides first when sneaking' do
    policy.sneaky = true
    policy.wander_wait = 0
    me[:hidden?] = false
    hide = instance_double(EO::Engine::Actions::Hide, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Hide).to receive(:new).with(world).and_return(hide)
    expect(wander.tick(world)).to be_success
  end

  it "uncovers a creature Lich's Overwatch saw hide here, once per room, before leaving" do
    policy.wander_wait = 0
    world[:hiders?] = true
    uncovered = 0
    allow(EO::Engine::Actions::Uncover).to receive(:new) do
      uncovered += 1
      instance_double(EO::Engine::Actions::Uncover, call: EO::Engine::Actions::Result.new(status: :success, reason: :searched))
    end
    expect(wander.tick(world).reason).to eq(:searched)
    expect(moves).to be_empty
    expect(wander.tick(world)).to be_success # still hiding: leave anyway
    expect(uncovered).to eq(1)
    expect(moves).to eq(['north'])

    room.id = 2
    wander.tick(world)
    expect(uncovered).to eq(2)

    world[:claim_mine?] = false
    room.id = 3
    expect(wander.tick(world)).to be_success
    expect(uncovered).to eq(2) # not our room: leave at once
  end

  it 'holds for the ambush after a hidden id appears on the combat dialog, then uncovers once, then leaves' do
    policy.wander_wait = 0
    uncovered = 0
    allow(EO::Engine::Actions::Uncover).to receive(:new) do
      uncovered += 1
      instance_double(EO::Engine::Actions::Uncover, call: EO::Engine::Actions::Result.new(status: :success, reason: :searched))
    end
    arrivals = []
    EO::Engine::Events.on(:hidden_arrival) { |e| arrivals << e.data[:ids] }
    world[:hidden_target_ids] = ['77']
    expect(wander.tick(world)).to be_nil # hold
    now[0] = Time.at(104)
    expect(wander.tick(world)).to be_nil
    world[:hidden_target_ids] = %w[77 78] # another arrives: the hold restarts
    expect(wander.tick(world)).to be_nil
    now[0] = Time.at(108)
    expect(wander.tick(world)).to be_nil
    now[0] = Time.at(110)
    expect(wander.tick(world).reason).to eq(:searched)
    expect(wander.tick(world)).to be_success
    expect(uncovered).to eq(1)
    expect(moves).to eq(['north'])
    expect(arrivals).to eq([['77'], ['78']])
  end

  it 'does not treat a target carried across a room change as a hidden arrival' do
    policy.wander_wait = 0
    room.targets = [OpenStruct.new(id: '77', name: 'greater krynch', noun: 'krynch', status: '', type: 'aggressive npc')]
    expect(wander.wants_control?(world)).to be false

    room.id = 2
    room.targets = []
    world[:hidden_target_ids] = ['77']
    expect(EO::Engine::Actions::Uncover).not_to receive(:new)
    expect(wander.tick(world)).to be_success
    expect(moves).to eq(['north'])
  end

  it 'goes home when outside the area' do
    policy.wander_wait = 0
    area = EO::Engine::Wander::Area.new(start: 1, boundaries: [9]).build(world)
    home = described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, clock: clock, area: area,
                               stance: ->(_s) { true }, travel: ->(r) { trips << r; true })
    room.id = 50
    expect(home.tick(world).reason).to eq(:returned_home)
    expect(trips).to eq([1])
    expect(moves).to be_empty
  end

  describe 'bandits and tracking' do
    let(:tracking) { EO::Engine::Tracking::Policy.new(bandits: true, creature: 'giant rat') }
    let(:hunter) do
      described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, clock: clock, tracking: tracking,
                          stance: ->(s) { stances << s; true }, travel: ->(r) { trips << r; true })
    end

    before do
      policy.wander_wait = 0
      me.profession = 'Ranger'
      me.define_singleton_method(:cooldown_active?) { |_n| false }
    end

    def stub_action(klass, reason, status: :success)
      allow(klass).to receive(:new).and_return(instance_double(klass, call: EO::Engine::Actions::Result.new(status: status, reason: reason)))
    end

    it 'stays after a trail, and after a hidden quarry only in our room' do
      stub_action(EO::Engine::Actions::Track, :trail)
      uncovered = 0
      allow(EO::Engine::Actions::Uncover).to receive(:new) do
        uncovered += 1
        instance_double(EO::Engine::Actions::Uncover, call: EO::Engine::Actions::Result.new(status: :success, reason: :searched))
      end
      expect(hunter.tick(world).reason).to eq(:tracked)
      expect(uncovered).to eq(1)
      expect(moves).to be_empty

      room.id = 2 # a new room: track again
      stub_action(EO::Engine::Actions::Track, :here)
      expect(hunter.tick(world).reason).to eq(:tracked)
      expect(moves).to be_empty

      room.id = 3
      world[:claim_mine?] = false
      expect(hunter.tick(world)).to be_success # hidden here but the room is not ours: move on
      expect(moves).to eq(['north'])
    end

    it 'moves on when the track finds nothing' do
      stub_action(EO::Engine::Actions::Track, :too_old, status: :failed)
      expect(hunter.tick(world)).to be_success
      expect(moves).to eq(['north'])
    end
  end

  it 'leaves the room announcement to the engine' do
    rooms = []
    EO::Engine::Events.on(:entered_room) { |e| rooms << e.data[:room] }
    wander.wants_control?(world)
    room.id = 2
    wander.wants_control?(world)
    expect(rooms).to be_empty
  end
end
