# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Loadout::Selection do
  let(:baseline) { EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'ready:shield') }
  let(:sets) { { 'silver' => { 'right' => 'silver blade' }, 'ghosts' => { 'right' => 'keep', 'left' => 'empty' } } }
  let(:rules) { [{ 'set' => 'silver', 'target' => 'kobold' }] }
  let(:selection) { described_class.new(default: baseline, sets: sets, rules: rules) }
  let(:target) { OpenStruct.new(id: '1', name: 'a kobold', noun: 'kobold', type: 'aggressive npc') }
  let(:world) { double('world', creature: nil) }

  it 'retains the default for no target or no matching rule' do
    expect(selection.default).to equal(baseline)
    expect(selection.select(target: nil, world: world)).to equal(baseline)
    target.noun = 'orc'
    expect(selection.select(target: target, world: world)).to equal(baseline)
  end

  it 'inherits omitted hands from the default and caches the selected policy' do
    chosen = selection.select(target: target, world: world)
    expect(chosen.stash_arguments).to eq(right: 'silver blade', left: :shield)
    expect(selection.select(target: target, world: world)).to equal(chosen)
  end

  it 'uses Targets name and noun matching, including its anchored case-insensitive fragments' do
    target.name = 'KOBOLD'
    target.noun = 'creature'
    expect(selection.select(target: target, world: world)).not_to equal(baseline)
    target.name = 'kobold warrior'
    expect(selection.select(target: target, world: world)).to equal(baseline)
    regex = described_class.new(default: baseline, sets: sets, rules: [{ 'set' => 'silver', 'target' => 'kobold.*' }])
    expect(regex.select(target: target, world: world)).not_to equal(baseline)
  end

  it 'inherits the default aim and lets a set override or clear it' do
    baseline = EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty', aim: 'right eye')
    named = described_class.new(
      default: baseline,
      sets: { 'quiet' => { 'right' => 'silver blade' },
              'skull' => { 'right' => 'silver blade', 'aim' => 'head' },
              'none'  => { 'right' => 'silver blade', 'aim' => '' } },
      rules: [{ 'set' => 'skull', 'target' => 'kobold' }]
    )
    expect(named.select(target: target, world: world).aim_command).to eq('aim head')
    expect(baseline.aim_command).to eq('aim right eye')
  end

  it 'uses the first matching rule and honors explicit keep' do
    rules.unshift({ 'set' => 'ghosts', 'target' => 'kobold' })
    expect(selection.select(target: target, world: world).stash_arguments).to eq(right: :keep, left: nil)
  end

  it 'requires both selectors when target and type are provided' do
    rules.first['type'] = 'undead'
    expect(selection.select(target: target, world: world)).to equal(baseline)
    target.type = 'aggressive npc,undead'
    expect(selection.select(target: target, world: world)).not_to equal(baseline)
    target.noun = 'orc'
    expect(selection.select(target: target, world: world)).to equal(baseline)
  end

  %w[undead noncorporeal].each do |type|
    it "matches the #{type} tag with the existing condition semantics" do
      rules.replace([{ 'set' => 'silver', 'type' => type }])
      target.type = "aggressive npc,#{type}"
      expect(selection.select(target: target, world: world)).not_to equal(baseline)
      target.type = "not_#{type}"
      expect(selection.select(target: target, world: world)).to equal(baseline)
    end
  end

  it 'only matches living with a core template explicitly classified as not undead' do
    rules.replace([{ 'set' => 'silver', 'type' => 'living' }])
    expect(selection.select(target: target, world: world)).to equal(baseline)
    [nil, true].each do |undead|
      allow(world).to receive(:creature).with('1').and_return(OpenStruct.new(template: OpenStruct.new(undead: undead)))
      expect(selection.select(target: target, world: world)).to equal(baseline)
    end
    allow(world).to receive(:creature).with('1').and_return(OpenStruct.new(template: OpenStruct.new(undead: false)))
    expect(selection.select(target: target, world: world)).not_to equal(baseline)
    %w[undead noncorporeal].each do |type|
      target.type = type
      expect(selection.select(target: target, world: world)).to equal(baseline)
    end
  end

  it 'reports managed selectable sets even when the default keeps both hands' do
    selection = described_class.new(default: EO::Engine::Loadout::Policy.new, sets: sets, rules: rules)
    expect(selection).to be_managed
    expect(described_class.new(default: EO::Engine::Loadout::Policy.new, sets: {}, rules: [])).not_to be_managed
  end

  it 'does not activate management for saved sets that no rule selects' do
    selection = described_class.new(default: EO::Engine::Loadout::Policy.new, sets: sets, rules: [])
    expect(selection).not_to be_managed
  end

  {
    'sets must be a mapping'               => { sets: [] },
    'set names must be nonblank'           => { sets: { '' => {} } },
    'sets must contain hand mappings'      => { sets: { 'silver' => 'ready:weapon' } },
    'unknown hand keys are invalid'        => { sets: { 'silver' => { 'rigth' => 'empty' } } },
    'hand arrays are invalid'              => { sets: { 'silver' => { 'right' => ['empty'] } } },
    'hand booleans are invalid'            => { sets: { 'silver' => { 'right' => false } } },
    'ready references require a slot'      => { sets: { 'silver' => { 'right' => 'ready:' } } },
    'rules must be a sequence'             => { rules: {} },
    'rules must be mappings'               => { rules: ['silver'] },
    'rules require a set'                  => { rules: [{ 'target' => 'kobold' }] },
    'rules require a known set'            => { rules: [{ 'set' => 'missing', 'target' => 'kobold' }] },
    'rules require a selector'             => { rules: [{ 'set' => 'silver' }] },
    'unknown rule keys are invalid'        => { rules: [{ 'set' => 'silver', 'targte' => 'kobold' }] },
    'blank targets are invalid'            => { rules: [{ 'set' => 'silver', 'target' => '' }] },
    'target lists are invalid'             => { rules: [{ 'set' => 'silver', 'target' => ['kobold'] }] },
    'invalid target patterns fail eagerly' => { rules: [{ 'set' => 'silver', 'target' => '[' }] },
    'unknown types are invalid'            => { rules: [{ 'set' => 'silver', 'type' => 'dragon' }] },
    'null selectors are invalid'           => { rules: [{ 'set' => 'silver', 'target' => nil }] }
  }.each do |description, overrides|
    it description do
      expect { described_class.new(**{ default: baseline, sets: sets, rules: rules }.merge(overrides)) }
        .to raise_error(ArgumentError, /hunting_loadout/)
    end
  end
end
