# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

# Watch is the engine's subscription to Lich's parser seam: each fact
# arrives on the bus under the name the behaviors listen for, completed
# with what the moment knows.
RSpec.describe EO::Engine::Watch do
  let(:tracker) { Lich::Gemstone::Combat::Tracker }
  let(:seen) { [] }

  before do
    tracker.reset!
    EO::Engine::Events.on { |e| seen << [e.type, e.data] }
    stub_const('DownstreamHook', Class.new { def self.add(*); end; def self.remove(*); end })
    described_class.install!
  end

  after do
    described_class.uninstall!
    described_class.clear!
    EO::Engine::Events.reset!
  end

  it 'enables the tracker with attack events and subscribes to every message event, :ucs and :attack' do
    expect(tracker.enabled?).to be true
    expect(tracker.settings[:emit_attacks]).to be true
    expect(tracker.handlers.keys).to include(:disarm_seen, :bolted, :ucs, :attack)
    expect(tracker.names.keys).to eq(%w[eohunter:messages eohunter:ucs eohunter:attack])
  end

  it 'passes a message event through under its name with the line' do
    tracker.emit(:bolted, raw: 'You bolt!')
    expect(seen).to eq([[:bolted, { raw: 'You bolt!' }]])
  end

  it 'renames the item limit and the hive trap kinds, adding the room' do
    allow(EO::Engine::World).to receive(:new).and_return(OpenStruct.new(room: OpenStruct.new(id: 42)))
    tracker.emit(:item_limit, raw: 'x')
    tracker.emit(:hive_trap, kind: :ground, raw: 'y')
    expect(seen.map(&:first)).to eq(%i[too_many_items hive_trap])
    expect(seen.last.last).to include(kind: :hive_traps_ground, room_id: 42)
  end

  it 'adds the hands and the room to a disarm' do
    hands = OpenStruct.new(right: 'r', left: 'l')
    allow(EO::Engine::World).to receive(:new).and_return(OpenStruct.new(room: OpenStruct.new(id: 7, title: 'Kobold Village'), hands: hands))
    tracker.emit(:disarm_seen, kind: :recover, noun: 'katana', raw: 'z')
    expect(seen.first.last).to include(kind: :recover, noun: 'katana', hands: hands, room_id: 7, title: 'Kobold Village')
  end

  it 'says whether a shrugged bless was ours' do
    me = OpenStruct.new(inventory_ids: ['5'])
    hands = OpenStruct.new(right: OpenStruct.new(noun: 'bow'), left: OpenStruct.new(noun: ''))
    allow(EO::Engine::World).to receive(:new).and_return(OpenStruct.new(me: me, hands: hands))
    tracker.emit(:bless_shrugged, id: '5', noun: 'arrow', raw: 'a')
    tracker.emit(:bless_shrugged, id: '9', noun: 'bow', raw: 'b')
    tracker.emit(:bless_shrugged, id: '9', noun: 'sword', raw: 'c')
    expect(seen.map { |_, d| d[:mine] }).to eq([true, true, false])
  end

  it 'turns the UCS facts into the unarmed tier and followup' do
    tracker.emit(:ucs, id: 1, name: 'kobold', kind: :position, value: 'good', tier: 2)
    tracker.emit(:ucs, id: 1, name: 'kobold', kind: :tierup, value: 'jab', tier: nil)
    tracker.emit(:ucs, id: 1, name: 'kobold', kind: :smite_on, value: nil, tier: nil)
    expect(seen).to eq([[:unarmed_tier, { tier: 2, id: 1 }], [:unarmed_followup, { attack: 'jab', id: 1 }]])
  end

  it 'turns an inbound attack into the incoming swing and our own rolls into force rolls' do
    tracker.emit(:attack, inbound: true, attacker: { id: 77, name: 'a kobold' }, resolutions: [{ result: 150 }])
    tracker.emit(:attack, inbound: false, resolutions: [{ result: 120 }, { result: 98 }])
    tracker.emit(:attack, inbound: false, foreign_caster: true, resolutions: [{ result: 200 }])
    expect(seen).to eq([[:incoming_swing, { target_id: '77' }], [:force_roll, { roll: 120 }], [:force_roll, { roll: 98 }]])
  end

  it 'turns another player\'s attack into an ally attack by name, and nothing when unnamed' do
    tracker.emit(:attack, foreign_caster: true, attacker: { name: 'Skooshii' }, resolutions: [{ result: 200 }])
    tracker.emit(:attack, foreign_caster: true, attacker: nil)
    tracker.emit(:attack, foreign_caster: true, attacker: { id: -5 })
    expect(seen).to eq([[:ally_attacked, { name: 'Skooshii' }]])
  end

  it 'keeps a hook only for rules of its own, such as the profile flee text' do
    hooks = []
    stub_const('DownstreamHook', Class.new do
      define_singleton_method(:add) { |name, *| hooks << name }
      define_singleton_method(:remove) { |name| hooks.delete(name) }
    end)
    described_class.uninstall!
    described_class.install!
    expect(hooks).to be_empty
    described_class.on(/run away/, :flee_message)
    described_class.install!
    expect(hooks).to eq([EO::Engine::HOOK_NAME])
    described_class.process('You had better run away now.')
    expect(seen.last).to eq([:flee_message, { raw: 'You had better run away now.' }])
  end
end
