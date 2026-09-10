# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

CleanseSpell = Struct.new(:num, :known, :affordable, :active, keyword_init: true) do
  def known? = known
  def affordable? = affordable
  def active? = active
  def available? = known && affordable
  def cast(*_a) = (@casts = (@casts || 0) + 1; 'Cast Roundtime 3 Seconds.')
  def force_incant(*_a) = cast
  def casts = @casts || 0
end unless defined?(CleanseSpell)

RSpec.describe EO::Engine::Cleanse::Policy do
  it 'reads ecleanse.yaml and falls back to CharSettings defaults' do
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'ecleanse.yaml')
      File.write(path, ":cleanse_poison: true\n:use_213: true\n:safe_room: '1234'\n")
      p = described_class.load(path, char_settings: { 'cleanse_disease' => true })
      expect(p.cleanse_poison).to be true
      expect(p.cleanse_disease).to be true
      expect(p.use_213).to be true
      expect(p.safe_room).to eq('1234')
      expect(p.use_flee).to be false
      missing = described_class.load(File.join(dir, 'nope.yaml'), char_settings: { 'avoid_webs' => true })
      expect(missing.avoid_webs).to be true
      expect(missing.cleanse_poison).to be false
    end
  end
end

RSpec.describe EO::Engine::Cleanse::Casting do
  let(:me) { OpenStruct.new(injuries: {}) }
  let(:spells) { {} }
  let(:world) { OpenStruct.new(me: me, spell: spells) }
  let(:policy) { EO::Engine::Cleanse::Policy.new }

  def hurt(area, wound: 0, scar: 0) = me.injuries[area] = { 'wound' => wound, 'scar' => scar }

  it 'casts with no injuries and refuses at rank 3, or rank 2 on the head or nerves' do
    expect(described_class.able?(world, policy)).to be true
    hurt('leftArm', wound: 1)
    expect(described_class.able?(world, policy)).to be true
    hurt('leftHand', wound: 1) # stacked left 2
    expect(described_class.able?(world, policy)).to be false
    me.injuries.clear
    hurt('head', wound: 2)
    expect(described_class.able?(world, policy)).to be false
    hurt('head', wound: 3)
    expect(described_class.able?(world, policy)).to be false
  end

  it 'lets the Sigil of Determination lift a rank-2 block but never rank 3' do
    policy.determination = true
    spells['Sigil of Determination'] = CleanseSpell.new(num: 0, known: true, affordable: true, active: false)
    hurt('rightArm', wound: 2)
    expect(described_class.able?(world, policy)).to be true
    hurt('rightArm', wound: 3)
    expect(described_class.able?(world, policy)).to be false
  end
end

RSpec.describe EO::Engine::Cleanse::Predicates do
  let(:me) do
    OpenStruct.new(injuries: {}, poisoned?: false, diseased?: false, stunned?: false, webbed?: false, bound?: false, hidden?: false,
                   stamina: 100, blessings_ranks: 0, debuff_names: [])
  end
  let(:spells) { {} }
  let(:room) { OpenStruct.new(id: 1, title: '[Kobold Village]', loot: [], targets: []) }
  let(:world) { OpenStruct.new(me: me, spell: spells, room: room) }
  let(:policy) { EO::Engine::Cleanse::Policy.new }
  let(:state) { EO::Engine::Cleanse::State.new }

  before do
    %i[debuff_active? cooldown_active? spell_active? effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
    allow(described_class).to receive(:cman_known?).and_return(false)
    allow(described_class).to receive(:cman_available?).and_return(false)
    allow(described_class).to receive(:feat_available?).and_return(false)
  end

  def spell(num, **o) = spells[num] = CleanseSpell.new(num: num, known: true, affordable: true, active: false, **o)

  def reason = described_class.reason(world, policy, state)

  it 'is nil when nothing is wrong or nothing is enabled' do
    expect(reason).to be_nil
    me[:poisoned?] = true
    expect(reason).to be_nil
    policy.cleanse_poison = true
    expect(reason).to be_nil # no 114
    spell(114)
    expect(reason).to eq(:poison)
  end

  it 'puts queued line events first, then the afflictions in ecleanse order' do
    policy.cleanse_poison = policy.cleanse_disease = true
    spell(114); spell(113)
    me[:poisoned?] = me[:diseased?] = true
    expect(reason).to eq(:poison)
    me[:poisoned?] = false
    expect(reason).to eq(:disease)
    state.enqueue(event: :use_vat)
    expect(reason).to eq(:queued)
  end

  it 'only claims a stun it has a means for' do
    me[:stunned?] = true
    expect(reason).to be_nil
    policy.use_stunned1040 = true
    spell(1040)
    expect(reason).to eq(:stun)
    spells.clear
    policy.use_flee = true
    allow(described_class).to receive(:cman_available?).with('Stun Maneuvers', min_rank: 5).and_return(true)
    expect(reason).to eq(:stun)
    room.title = '[The Belly of the Beast]'
    expect(reason).to be_nil
  end

  it 'finds the hazards on the floor, skipping bad targets, gems and the invalid clouds' do
    policy.dispel_magic = policy.avoid_webs = policy.break_runestone = true
    spell(417); spell(209)
    room.loot = [OpenStruct.new(id: '1', name: 'cloud of thick ethereal fog', noun: 'fog', type: ''),
                 OpenStruct.new(id: '2', name: 'a cloud agate', noun: 'agate', type: 'gem'),
                 OpenStruct.new(id: '3', name: 'a noxious cloud', noun: 'cloud', type: '')]
    expect(reason).to eq(:cloud)
    state.bad_target!('3')
    expect(reason).to be_nil
    room.loot << OpenStruct.new(id: '4', name: 'a silvery blue globe', noun: 'globe', type: '')
    expect(reason).to eq(:globe)
    room.loot = [OpenStruct.new(id: '5', name: 'a pale hovering runestone', noun: 'runestone', type: '')]
    expect(reason).to eq(:runestone)
    room.loot = [OpenStruct.new(id: '6', name: 'a sticky web', noun: 'web', type: '')]
    expect(reason).to eq(:web)
  end

  it 'reads the grounded and magical debuffs' do
    me.debuff_names = ['Rooted']
    policy.cleanse_grounded = true
    expect(reason).to be_nil
    allow(described_class).to receive(:cman_known?).with('Retreat').and_return(true)
    expect(reason).to eq(:grounded)
    me.debuff_names = ['Confusion']
    policy.cleanse_magical = true
    spell(417)
    expect(reason).to eq(:magical)
  end
end

RSpec.describe EO::Engine::Behaviors::Cleanse do
  let(:me) do
    OpenStruct.new(injuries: {}, poisoned?: true, diseased?: false, stunned?: false, webbed?: false, bound?: false, hidden?: false,
                   dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stamina: 100, blessings_ranks: 0, debuff_names: [])
  end
  let(:spells) { { 114 => CleanseSpell.new(num: 114, known: true, affordable: true, active: false) } }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(id: '77', noun: 'katana'), left: OpenStruct.new(id: nil, noun: '')) }
  let(:room) { OpenStruct.new(id: 1, title: '[Kobold Village]', loot: [], targets: [], creatures: []) }
  let(:world) { OpenStruct.new(me: me, spell: spells, room: room, hands: hands) }
  let(:policy) { EO::Engine::Cleanse::Policy.new(cleanse_poison: true, recover_disarmed: true) }
  let(:cleanse) { described_class.new(policy: policy) }

  before do
    %i[debuff_active? cooldown_active? spell_active? effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
    allow(EO::Engine::Cleanse::Predicates).to receive(:cman_known?).and_return(false)
    allow_any_instance_of(EO::Engine::Actions::CleanseAffliction).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::CleanseAffliction).to receive(:send_and_match).and_return(EO::Engine::Actions::Result.new(status: :success, line: 'ok'))
  end

  after { EO::Engine::Events.reset! }

  it 'is priority 5 and casts the poison cure until it clears' do
    expect(cleanse.priority).to eq(5)
    casts = 0
    allow(spells[114]).to receive(:cast) { casts += 1; me[:poisoned?] = casts >= 2 ? false : true; 'x' }
    expect(cleanse.wants_control?(world)).to be true
    expect(cleanse.tick(world).reason).to eq(:poison)
    expect(casts).to eq(2)
    expect(cleanse.wants_control?(world)).to be false
  end

  it 'records a disarm from the watch and runs the recovery from the queue' do
    me[:poisoned?] = false
    cleanse
    EO::Engine::Events.emit(:disarm_seen, kind: :recover, noun: 'katana', hands: hands, room_id: 1, title: 'Kobold Village')
    expect(cleanse.state.recover.size).to eq(1)
    expect(cleanse.state.recover[0][:known_ids]).to eq(['77'])
    expect(cleanse.wants_control?(world)).to be true
    recover = instance_double(EO::Engine::Actions::CleanseRecover, call: EO::Engine::Actions::Result.new(status: :success, reason: :recovered))
    expect(EO::Engine::Actions::CleanseRecover).to receive(:new).with(world, record: hash_including(noun: 'katana'), policy: policy, travel: nil).and_return(recover)
    expect(cleanse.tick(world).reason).to eq(:recovered)
    expect(cleanse.state.recover).to be_empty
    expect(cleanse.wants_control?(world)).to be false
  end

  it 'ignores a disarm when recovery is off' do
    policy.recover_disarmed = false
    cleanse
    EO::Engine::Events.emit(:disarm_seen, kind: :recover, noun: 'katana', hands: hands, room_id: 1, title: 'x')
    expect(cleanse.state.queue).to be_empty
  end

  it 'queues the hive trap with its room and clears it when handled' do
    me[:poisoned?] = false
    policy.hive_traps_ground = true
    cleanse
    EO::Engine::Events.emit(:hive_trap, kind: :hive_traps_ground, room_id: 1)
    expect(cleanse.state.hive_trap_room).to eq(1)
    trap = instance_double(EO::Engine::Actions::CleanseHiveTrap, call: EO::Engine::Actions::Result.new(status: :success, reason: :clear))
    expect(EO::Engine::Actions::CleanseHiveTrap).to receive(:new).and_return(trap)
    cleanse.wants_control?(world)
    expect(cleanse.tick(world).reason).to eq(:clear)
  end
end

RSpec.describe EO::Engine::Actions::CleanseRecover do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, kneeling?: false, standing?: true, injuries: {}) }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(id: nil, name: 'Empty', noun: ''), left: OpenStruct.new(id: '5', name: 'a shield', noun: 'shield')) }
  let(:room) { OpenStruct.new(id: 1, title: 'x', targets: [], creatures: []) }
  let(:world) { OpenStruct.new(me: me, room: room, hands: hands, spell: {}) }
  let(:record) { { noun: 'katana', known_ids: ['5'], room_id: 1, title: 'Kobold Village' } }
  let(:sent) { [] }

  before do
    me.define_singleton_method(:spell_active?) { |_n| false }
    allow(EO::Engine::Cleanse::Casting).to receive(:able?).and_return(false)
  end

  def recover
    action = described_class.new(world, record: record, policy: EO::Engine::Cleanse::Policy.new, travel: ->(_r) { true })
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; me[:standing?] = true if cmd == 'stand'; 'ok' }
    allow(action).to receive(:send_and_match) { |cmd, _rx, **| sent << cmd; (me[:kneeling?] = true; me[:standing?] = false) if cmd == 'kneel'; EO::Engine::Actions::Result.new(status: :success, line: 'You kneel.') }
    allow(action).to receive(:sleep)
    allow(action).to receive(:bonded?).and_return(false)
    allow(action).to receive(:fill_hands)
    allow(action).to receive(:stance_defensive)
    action
  end

  it 'kneels and recovers until the game confirms, then stands and refills' do
    action = recover
    tries = 0
    allow(action).to receive(:command_lines) { tries += 1; tries == 2 ? ['You spy a katana and recover it!'] : ['You continue to intently search the area'] }
    result = action.call
    expect(result).to be_success
    expect(result.reason).to eq(:recovered)
    expect(sent.first).to eq('stow all')
    expect(sent.count('kneel')).to eq(1)
    expect(sent.last).to eq('stand')
  end

  it 'treats a new item in hand as recovered when no message comes, and gives up after ten' do
    action = recover
    allow(action).to receive(:command_lines) { hands.right = OpenStruct.new(id: '9', name: 'a katana', noun: 'katana'); [] }
    expect(action.call.reason).to eq(:recovered)
    hands.right = OpenStruct.new(id: nil, name: 'Empty', noun: '')
    other = recover
    allow(other).to receive(:command_lines).and_return([])
    expect(other.call.reason).to eq(:not_recovered)
  end

  it 'stops and reports when unable to search' do
    action = recover
    stuck = []
    EO::Engine::Events.on(:cleanse_stuck) { |e| stuck << e.data[:reason] }
    allow(action).to receive(:command_lines).and_return(["You're not in any condition to be searching around."])
    expect(action.call.reason).to eq(:cannot_search)
    expect(stuck.first).to match(/katana is in room 1/)
  ensure
    EO::Engine::Events.reset!
  end
end
