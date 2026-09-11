# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Behaviors::Rest, 'encumbrance settling' do
  let(:clock) { OpenStruct.new(now: 100.0) }
  let(:me) do
    OpenStruct.new(fxp_pct: 0, mana_pct: 100, encumbrance_pct: 70,
                   debuff_level: nil, debuff_active?: false)
  end
  let(:world) { OpenStruct.new(me: me) }
  let(:policy) { EO::Engine::Rest::Policy.new(encumbered: 60) }
  let(:rest) { described_class.new(policy: policy, clock: clock) }

  it 'does not commit a town return for a box briefly held before disk storage' do
    expect(rest.wants_control?(world)).to be false
    clock.now += 2
    me.encumbrance_pct = 10
    expect(rest.wants_control?(world)).to be false
    clock.now += 10
    expect(rest.wants_control?(world)).to be false
    expect(rest.phase).to eq(:hunting)
  end

  it 'returns for continuously overweight state after the grace interval' do
    expect(rest.wants_control?(world)).to be false
    clock.now += 5
    expect(rest.wants_control?(world)).to be true
    expect(rest.reason).to eq('encumbered.')
  end

  it 'resets the grace interval when weight dips below the threshold' do
    expect(rest.wants_control?(world)).to be false
    clock.now += 4
    me.encumbrance_pct = 10
    expect(rest.wants_control?(world)).to be false
    me.encumbrance_pct = 70
    expect(rest.wants_control?(world)).to be false
    clock.now += 4
    expect(rest.wants_control?(world)).to be false
    clock.now += 1
    expect(rest.wants_control?(world)).to be true
  end

  it 'never postpones wounds or an explicit failed-storage request' do
    policy.wounded = -> { true }
    expect(rest.wants_control?(world)).to be true
    expect(rest.reason).to eq('wounded.')
    rest.rest!('Could not store box')
    expect(rest.wants_control?(world)).to be true
    expect(rest.reason).to eq('Could not store box')
  end

  it 'supports an explicit zero grace interval' do
    policy.encumbrance_grace = 0
    expect(rest.wants_control?(world)).to be true
  end

  it 'starts fresh after loot releases, including delayed weight updates' do
    loot = OpenStruct.new(looting?: true)
    hunter = described_class.new(policy: policy, clock: clock, loot: loot)
    expect(hunter.wants_control?(world)).to be false
    clock.now += 15
    expect(hunter.wants_control?(world)).to be false
    loot[:looting?] = false
    expect(hunter.wants_control?(world)).to be false
    clock.now += 2
    me.encumbrance_pct = 0
    expect(hunter.wants_control?(world)).to be false
  end

  it 'uses the same grace decision for follower reports' do
    world.room = OpenStruct.new(id: 1)
    me[:in_rt?] = false
    me[:in_cast_rt?] = false
    me[:hidden?] = false
    me.spirit = 10
    me.stamina_pct = 100
    meter = EO::Engine::Rest::Encumbrance.new(clock: clock)
    report = lambda do
      EO::Engine::Group.report(world, name: 'Follower', rest_policy: policy,
                               counters: EO::Engine::Rest::Counters.new, encumbrance: meter)
    end
    expect(report.call.rest_reason).to be_nil
    clock.now += 5
    expect(report.call.rest_reason).to eq('encumbered.')
  end
end
