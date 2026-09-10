# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

# bigshot 5.16's newer command checks: thp, empowered, the crtrStatus
# statuses and flags, the Tracker facts, and the coup de grace gate.
RSpec.describe 'engage checks from bigshot 5.16' do
  FakeCreature = Struct.new(:statuses, :flags, :hp_percent, :current_hp, :max_hp, :low, :fatal, :smote, :ucs, :tierup, keyword_init: true) do
    def has_status?(s) = Array(statuses).include?(s.to_s)
    def crtr_flag?(f) = Array(flags).include?(f.to_sym)
    def low_hp?(_t = 25) = low
    def fatal_crit? = fatal
    def smote? = smote
    def ucs_position = ucs
    def ucs_tierup = tierup
  end unless defined?(FakeCreature)

  let(:me) { OpenStruct.new(mana: 100, stamina: 100, spirit: 10, health_pct: 100, encumbrance_pct: 0, kneeling?: false, hidden?: false, diseased?: false, poisoned?: false, shadow_essence: 0) }
  let(:creature) { FakeCreature.new(statuses: [], flags: [], hp_percent: 50, current_hp: 100, max_hp: 200, low: false, fatal: false, smote: false, ucs: nil, tierup: nil) }
  let(:world) { OpenStruct.new(me: me, room: OpenStruct.new(targets: [], players: []), group_nouns: []) }
  let(:target) { OpenStruct.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc') }
  let(:state) { EO::Engine::Engage::State.new }
  let(:buffs) { [] }

  before do
    c = creature
    world.define_singleton_method(:creature) { |id| id.to_s == '1' ? c : nil }
    active = buffs
    me.define_singleton_method(:effect_active?) { |n| active.any? { |b| n.is_a?(Regexp) ? b =~ n : b == n } }
    me.define_singleton_method(:buff_bonus) { |rx| active.filter_map { |b| b[rx, 1]&.to_i }.max }
    me.define_singleton_method(:buff_time_left) { |_n| 0.5 }
    %i[buff_matching? spell_active? spell_effect_active? cooldown_active? debuff_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
  end

  def blocked(raw)
    line = EO::Engine::Engage::Routine.parse([raw]).first
    EO::Engine::Engage::Conditions.blocked_by(line, world, target, state, EO::Engine::Targets::Policy.new)
  end

  it 'reads thp against the creature HP percent, skipping when unknown' do
    expect(blocked('coupdegrace (thp20)')).to eq('thp20')
    creature.hp_percent = 15
    expect(blocked('coupdegrace (thp20)')).to be_nil
    expect(blocked('coupdegrace (!thp20)')).to eq('!thp20')
    creature.hp_percent = nil
    expect(blocked('coupdegrace (thp20)')).to eq('thp20')
  end

  it 'reads empowered against the strongest Empowered buff' do
    expect(blocked('coupdegrace (empowered30)')).to be_nil
    buffs << 'Empowered (+20)'
    expect(blocked('coupdegrace (empowered30)')).to be_nil
    buffs << 'Empowered (+35)'
    expect(blocked('coupdegrace (empowered30)')).to eq('empowered30')
    expect(blocked('coupdegrace (!empowered30)')).to be_nil
  end

  it 'vetoes buffN only while the buff is up and expiring, keyed on the command word' do
    expect(blocked('coupdegrace (buff30)')).to be_nil
    buffs << 'Empowered (+20)'
    expect(blocked('coupdegrace (buff30)')).to eq('buff30')
    me.define_singleton_method(:buff_time_left) { |_n| 5.0 }
    expect(blocked('coupdegrace (buff30)')).to be_nil
  end

  it 'reads the crtrStatus statuses and flags natively, positional ones for prone' do
    expect(blocked('cman trip (stunned)')).to eq('stunned')
    creature.statuses = ['stunned']
    expect(blocked('cman trip (stunned)')).to be_nil
    expect(blocked('cman trip (!stunned)')).to eq('!stunned')
    expect(blocked('cman trip (prone)')).to eq('prone') # stunned counts as prone
    expect(blocked('attack (mini_boss)')).to eq('mini_boss')
    creature.flags = [:mini_boss]
    expect(blocked('attack (mini_boss)')).to be_nil
    creature.statuses = ['immobilized']
    expect(blocked('attack (frozen)')).to eq('frozen')
  end

  it 'reads the Tracker facts' do
    expect(blocked('attack (wounded)')).to eq('wounded')
    creature.low = true
    expect(blocked('attack (wounded)')).to be_nil
    expect(blocked('attack (ucsgood)')).to eq('ucsgood')
    creature.ucs = 2
    expect(blocked('attack (ucsgood)')).to be_nil
    expect(blocked('attack (ucstierup)')).to eq('ucstierup')
    expect(blocked('attack (!ucstierup)')).to be_nil
    creature.tierup = 'jab'
    expect(blocked('attack (ucstierup)')).to be_nil
    expect(blocked('attack (!ucstierup)')).to eq('!ucstierup')
  end

  it 'falls back to the status string for a creature Lich does not know' do
    target.id = '9'
    target.status = 'lying down'
    expect(blocked('cman trip (prone)')).to eq('prone')
    expect(blocked('cman trip (stunned)')).to eq('stunned')
  end

  describe EO::Engine::Engage::Coup do
    it 'holds the coup above the rank threshold and sends at or below it' do
      creature.current_hp = 100
      expect(described_class.hold_reason(world, target, rank: 3)).to eq(:coup_not_ready) # 15% of 200 = 30
      creature.current_hp = 30
      expect(described_class.hold_reason(world, target, rank: 3)).to be_nil
      creature.current_hp = 60
      creature.statuses = ['stunned']
      expect(described_class.hold_reason(world, target, rank: 3)).to be_nil # 30% of 200 = 60
    end

    it 'caps the threshold at 200 HP and passes unknown targets through' do
      creature.max_hp = 10_000
      creature.current_hp = 250
      creature.statuses = ['stunned']
      expect(described_class.hold_reason(world, target, rank: 5)).to eq(:coup_not_ready)
      creature.current_hp = 200
      expect(described_class.hold_reason(world, target, rank: 5)).to be_nil
      target.id = '9'
      expect(described_class.hold_reason(world, target, rank: 5)).to be_nil
      expect(described_class.hold_reason(world, target, rank: 0)).to be_nil
    end
  end
end
