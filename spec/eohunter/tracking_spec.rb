# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Tracking do
  it 'reads bandit mode from the word or the bounty, and the quarry after track' do
    expect(described_class.policy_from([]).bandits?).to be false
    expect(described_class.policy_from(['bandits']).bandits?).to be true
    expect(described_class.policy_from([], bounty: 'You have been tasked to suppress bandit activity in the area.').bandits?).to be true
    expect(described_class.policy_from([], bounty: 'You have been tasked to hunt down and kill 12 kobolds.').bandits?).to be false
    p = described_class.policy_from(%w[track giant rat])
    expect(p.creature_name).to eq('giant rat')
    expect(p.tracking?).to be true
    expect(described_class.policy_from(['track']).tracking?).to be false
  end

  it 'hunts only the bandit nouns, on the quick routine, in bandit mode' do
    policy = EO::Engine::Targets::Policy.new(wanted: described_class.bandit_targets)
    roster = [OpenStruct.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc'),
              OpenStruct.new(id: '2', name: 'human brigand', noun: 'brigand', status: '', type: 'bandit'),
              OpenStruct.new(id: '3', name: 'elven highwayman', noun: 'highwayman', status: '', type: 'bandit')]
    expect(EO::Engine::Targets.candidates(roster, policy).map(&:id)).to eq(%w[2 3])
    expect(EO::Engine::Targets.routine_for(roster[1], policy)).to eq('quick')
  end
end

RSpec.describe EO::Engine::Actions::BanditLook do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false) }
  let(:room) { OpenStruct.new(id: 1, targets: []) }
  let(:registered) { [] }
  let(:targeted) { [] }
  let(:world) { OpenStruct.new(me: me, room: room) }

  before do
    reg = registered
    tgt = targeted
    world.define_singleton_method(:register_npc) { |id, noun, name| reg << [id, noun, name] }
    world.define_singleton_method(:add_current_target) { |id| tgt << id }
  end

  def look(lines)
    action = described_class.new(world)
    allow(action).to receive(:look_lines).and_return(lines)
    allow(action).to receive(:settle_rt)
    action
  end

  it 'finds the bandit in the look, registers it and puts it first in the target ids' do
    lines = ['<resource picture="0"/><style id="roomName"/>[Trail]<style id=""/>',
             'You also see <a exist="123" noun="brigand">a scruffy  human brigand</a> and <a exist="9" noun="rat">a rat</a>.']
    result = look(lines).call
    expect(result).to be_success
    expect(result.reason).to eq(:bandit_found)
    expect(registered).to eq([['123', 'brigand', 'a scruffy human brigand']])
    expect(targeted).to eq(['123'])
  end

  it 'does not register a bandit the target list already has' do
    room.targets = [OpenStruct.new(id: '123')]
    look(['<a exist="123" noun="thug">a thug</a>']).call
    expect(registered).to be_empty
    expect(targeted).to eq(['123'])
  end

  it 'fails quietly when no bandit is in the look' do
    result = look(['<a exist="9" noun="rat">a rat</a>']).call
    expect(result.reason).to eq(:no_bandit)
    expect(registered).to be_empty
  end
end

RSpec.describe EO::Engine::Actions::Track do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, profession: 'Ranger') }
  let(:world) { OpenStruct.new(me: me, room: OpenStruct.new(id: 1, targets: [])) }
  let(:sent) { [] }

  before { me.define_singleton_method(:cooldown_active?) { |_n| false } }

  def track(reply, creature: 'giant rat')
    action = described_class.new(world, creature: creature)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:send_and_match) { |cmd, _rx, **| sent << cmd; EO::Engine::Actions::Result.new(status: :success, line: reply) }
    action
  end

  it 'follows a trail and reports a quarry hidden here as success' do
    expect(track('Your keen eye spots the beginnings of a trail and you rush to follow it.').call.reason).to eq(:trail)
    expect(track("You don't have to go far.").call.reason).to eq(:here)
    expect(sent).to eq(['track giant rat', 'track giant rat'])
  end

  it 'fails with the game\'s reason otherwise' do
    expect(track('A giant rat was here, but the trail is clearly too old to be worth following.').call.reason).to eq(:too_old)
    expect(track("You don't know how to track creatures within town.").call.reason).to eq(:town)
  end

  it 'refuses for a non-Ranger, on cooldown, or with no creature' do
    expect(track('x', creature: '').call.reason).to eq(:no_creature)
    me.profession = 'Warrior'
    expect(track('x').call.reason).to eq(:not_a_ranger)
    me.profession = 'Ranger'
    me.define_singleton_method(:cooldown_active?) { |n| n == 'Tracking' }
    expect(track('x').call.reason).to eq(:cooldown)
    expect(sent).to be_empty
  end
end

RSpec.describe EO::Engine::Actions::Uncover do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, profession: 'Ranger') }
  let(:spells) { {} }
  let(:room) { OpenStruct.new(id: 1, targets: []) }
  let(:world) { OpenStruct.new(me: me, room: room, spell: spells) }
  let(:sent) { [] }

  def uncover
    action = described_class.new(world)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; 'ok' }
    action
  end

  it 'searches, or casts 609 open for a Ranger who has it' do
    expect(uncover.call.reason).to eq(:searched)
    spells[609] = OpenStruct.new(known?: true, affordable?: true)
    expect(uncover.call.reason).to eq(:spell_609)
    expect(sent).to eq(['search', 'incant 609 open'])
  end

  it 'does nothing with something hostile already showing' do
    room.targets = [OpenStruct.new(id: '1')]
    expect(uncover.call.reason).to eq(:creatures_here)
    expect(sent).to be_empty
  end
end
