# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::BuffPolicy do
  let(:clock) { OpenStruct.new(now: 100.0) }
  let(:spells) { {} }
  let(:me) { double('Me', effect_active?: false) }
  let(:world) { OpenStruct.new(me: me, spell: spells) }
  let(:raw) { { 'enabled' => true, 'spells' => { 406 => 'recast', 911 => 'warn', 219 => 'field' } } }
  let(:policy) { described_class::Policy.new(raw) }
  let(:buffs) { described_class::Coordinator.new(policy: policy, clock: clock) }

  before do
    [406, 911, 219].each do |id|
      spells[id] = double("Spell #{id}", name: "Spell #{id}", active?: true, known?: true, affordable?: true, type: 'defense', time_per: 120)
    end
  end
  after { EO::Engine::Events.reset! }

  it 'does not read game state when disabled' do
    off = described_class::Coordinator.new(policy: described_class::Policy.new)
    expect(off.assess(double('unavailable world'))).to eq([])
    expect(off.manages?(406)).to be false
  end

  it 'detects loss, requests native recast, and clears only on observation' do
    expect(buffs.assess(world)).to be_empty
    allow(spells[406]).to receive(:active?).and_return(false)
    expect(buffs.assess(world).map(&:state)).to eq(['recast'])
    buffs.attempted!(406)
    expect(buffs.assess(world).map(&:state)).to eq(['pending'])
    expect(buffs.missing_required(world)).to eq([406])
    allow(spells[406]).to receive(:active?).and_return(true)
    expect(buffs.assess(world)).to be_empty
  end

  it 'bounds unconfirmed attempts and requests recovery without pretending a cast restored it' do
    allow(spells[406]).to receive(:active?).and_return(false)
    2.times do
      buffs.attempted!(406)
      clock.now += 3
    end
    expect(buffs.rest_reason(world)).to eq(described_class::FIELD_REASON)
    allow(spells[406]).to receive(:active?).and_return(true)
    buffs.assess(world)
    allow(spells[406]).to receive(:active?).and_return(false)
    expect(buffs.assess(world).first.state).to eq('recast')
  end

  it 'accepts core Buffs observations by name even when Spell has not caught up' do
    allow(spells[406]).to receive(:active?).and_return(false)
    allow(me).to receive(:effect_active?).with('Spell 406').and_return(true)
    expect(buffs.assess(world)).to be_empty
  end

  it 'recovers for unknown and unaffordable spells rather than casting or buying supplies' do
    allow(spells[406]).to receive_messages(active?: false, known?: false)
    expect(buffs.rest_reason(world)).to eq(described_class::FIELD_REASON)
    allow(spells[406]).to receive_messages(known?: true, affordable?: false)
    expect(buffs.rest_reason(world)).to eq(described_class::FIELD_REASON)
    spells.delete(406)
    expect(buffs.rest_reason(world)).to eq(described_class::FIELD_REASON)
  end

  it 'warns once per changed state without blocking departure' do
    events = []
    EO::Engine::Events.on(:buff_policy_status) { |event| events << event.data }
    allow(spells[911]).to receive(:active?).and_return(false)
    5.times { expect(buffs.rest_reason(world)).to be_nil }
    expect(buffs.missing_required(world)).to be_empty
    expect(events.size).to eq(1)
    expect(events.first[:needs]).to eq([[911, 'warn']])
  end

  it 'lets town recovery outrank field recovery' do
    raw['spells'][406] = 'town'
    allow(spells[406]).to receive(:active?).and_return(false)
    allow(spells[219]).to receive(:active?).and_return(false)
    expect(buffs.rest_reason(world)).to eq(described_class::TOWN_REASON)
  end

  it 'does not treat attack spells, timers, untimed effects or missing metadata as native buffs' do
    allow(spells[406]).to receive(:active?).and_return(false)
    %w[attack attack/area/utility timer].each do |type|
      allow(spells[406]).to receive(:type).and_return(type)
      expect(buffs.rest_reason(world)).to eq(described_class::FIELD_REASON)
    end
    allow(spells[406]).to receive_messages(type: 'offense', time_per: 0)
    expect(buffs.rest_reason(world)).to eq(described_class::FIELD_REASON)
    allow(spells[406]).to receive_messages(type: nil, time_per: 120)
    expect(buffs.rest_reason(world)).to eq(described_class::FIELD_REASON)
    allow(spells[406]).to receive(:type).and_return('offense/utility')
    expect(buffs.assess(world).first.state).to eq('recast')
  end

  it 'applies a default response and per-spell overrides only to explicit spells' do
    raw['default_action'] = 'town'
    raw['spells'] = { 406 => {}, 911 => 'ignore' }
    allow(spells[406]).to receive(:active?).and_return(false)
    allow(spells[911]).to receive(:active?).and_return(false)
    expect(buffs.assess(world).map { |need| [need.rule.spell, need.state] }).to eq([[406, 'town']])
    expect(buffs.manages?(911)).to be true
    expect(buffs.manages?(117)).to be false
  end

  it 'rejects malformed configuration instead of silently weakening it' do
    invalid = [nil, [], { 'enabled' => 'false' }, { 'typo' => true },
               { 'enabled' => true }, { 'verify_seconds' => Float::NAN }, { 'max_attempts' => 0 },
               { 'mana_spellup_at' => 1 }, { 'mana_spellup_at' => '4' }, { 'mana_spellup_at' => -1 },
               { 'spells' => { '406junk' => 'recast' } }, { 'spells' => { 406 => 'recats' } },
               { 'spells' => { 406 => { 'action' => 'warn', 'required' => true } } },
               { 'spells' => { 406 => 'field', '406' => 'town' } }]
    invalid.each { |value| expect { described_class::Policy.new(value) }.to raise_error(ArgumentError) }
  end

  it 'validates the refuge and refuses unsupported modes before execution' do
    expect { EO::Engine::Profile.new({ 'combat_buffs' => raw }) }.to raise_error(ArgumentError, /resting_room_id/)
    profile = EO::Engine::Profile.new({ 'combat_buffs' => raw, 'resting_room_id' => 100 })
    expect(profile.validate_rest_mode!(nil)).to be true
    expect { profile.validate_rest_mode!('head') }.to raise_error(ArgumentError, /solo/)
    expect { profile.validate_rest_mode!('tail') }.to raise_error(ArgumentError, /solo/)
    expect { profile.validate_rest_mode!(nil, controlled: true) }.to raise_error(ArgumentError, /solo/)
    expect { profile.validate_rest_mode!(nil, bounty: true) }.to raise_error(ArgumentError, /solo/)
  end
end
