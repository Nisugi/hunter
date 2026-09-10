# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Profile do
  let(:raw) do
    {
      'resting_room_id' => '29877', 'resting_commands' => 'store all', 'fried' => '101', 'overkill' => '2', 'oom' => '',
      'encumbered' => '20', 'wounded_eval' => 'hp < 60', 'hunting_room_id' => 'u7000', 'hunting_boundaries' => '29900, 30115',
      'rest_till_exp' => '100', 'rest_till_mana' => '90', 'hunting_stance' => 'Offensive', 'wander_stance' => 'Defensive',
      'hunting_prep_commands' => 'ready weapon, incant 515', 'signs' => '515, 506, 605', 'loot_script' => 'eloot',
      'delay_loot' => true, 'sneaky_sneaky' => true, 'loot_stance' => true, 'pull' => false, 'flee_count' => '100',
      'wander_wait' => 0.3, 'bless' => false,
      'hunting_commands' => 'kweed(buff5), script volley, coupdegrace(thp20 empowered30), incant 608(!hidden), hide(!hidden), fire(hidden)',
      'hunting_commands_e' => 'attack(x2), stance offensive and attack',
      'targets' => 'mastodon(b), berserker(d), shield-maiden(e), skald(c), warg(a), (?:.+?)(d)',
      'quickhunt_targets' => '', 'mstrike_mob' => '', 'ignore_disks' => false, 'depart_switch' => true, 'boons_flee' => []
    }
  end
  let(:profile) { described_class.new(raw, name: 'ojandhaart', uid_ids: ->(uid) { uid == 7000 ? [29902] : [] }) }

  it 'reads numbers, blanks, booleans and stances the way clean_value does' do
    expect(profile['fried']).to eq(101)
    expect(profile['oom']).to eq(0)
    expect(profile['mstrike_mob']).to eq(2)
    expect(profile['delay_loot']).to be true
    expect(profile['pull']).to be false
    expect(profile['hunting_stance']).to eq('offensive')
    expect(profile['wander_wait']).to eq(0.3)
  end

  it 'resolves rooms, uids and boundary lists' do
    expect(profile['resting_room_id']).to eq(29877)
    expect(profile['hunting_room_id']).to eq(29902)
    expect(profile['hunting_boundaries']).to eq([29900, 30115])
  end

  it 'splits command lists with repeats and ands' do
    expect(profile['hunting_prep_commands']).to eq(['ready weapon', 'incant 515'])
    expect(profile['hunting_commands'].size).to eq(6)
    expect(profile['hunting_commands'].first).to eq('kweed(buff5)')
    expect(profile['hunting_commands_e']).to eq(['attack', 'attack', ['stance offensive', 'attack']])
  end

  it 'reads the targets list with letters and a default' do
    expect(profile['targets']).to eq('mastodon' => 'b', 'berserker' => 'd', 'shield-maiden' => 'e', 'skald' => 'c', 'warg' => 'a', '(?:.+?)' => 'd')
    expect(described_class.new({ 'targets' => 'kobold, orc(b)' })['targets']).to eq('kobold' => 'a', 'orc' => 'b')
  end

  it 'builds the policies' do
    hp = 50
    rest = profile.rest_policy(wounded_binding: binding)
    expect(rest.fried_pct).to eq(101)
    expect(rest.resting_room).to eq(29877)
    expect(rest.wounded.call).to be true
    expect(profile.targets_policy.matchers.map(&:last)).to eq(%w[b d e c a d])
    expect(profile.wander_policy.sneaky).to be true
    expect(profile.wander_policy.boundary_ids).to eq([29900, 30115])
    expect(profile.loot_policy.script).to eq('eloot')
    expect(profile.maintain_policy.signs).to eq(%w[515 506 605])
    expect(profile.survival_policy.on_death).to eq(:depart)
    expect(profile.engage_policy.routine_for('a').size).to eq(6)
    expect(profile.engage_policy.routine_for('c').size).to eq(6) # empty letters fall back to a
    expect(profile.engage_policy.hunting_stance).to eq('offensive')
    expect(profile.flee_policy.count).to eq(100)
  end
end
