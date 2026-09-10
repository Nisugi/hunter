# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Actions::Maneuver do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false) }
  let(:world) { OpenStruct.new(me: me) }
  let(:kobold) { OpenStruct.new(id: '1234', name: 'kobold', noun: 'kobold') }
  let(:sent) { [] }
  # A stand-in for Lich's CMan / Weapon / ... readers (lich-5 #1583).
  let(:reader) do
    double('reader', known?: true, affordable?: true, available?: true, buff_active?: false)
  end

  before do
    me.define_singleton_method(:debuff_active?) { |_n| false }
    allow(reader).to receive(:command) do |name, target, forcert_count: 0|
      cmd = "cman #{name.downcase.delete(' ')}"
      cmd += target.is_a?(Integer) ? " ##{target}" : " #{target}" unless target.to_s.empty?
      cmd += ' forcert' if forcert_count > 0
      cmd
    end
    allow(reader).to receive(:results_regex) do |_name, results_of_interest: nil|
      Regexp.union(/You dip your shoulder and rush/, /^Roundtime: \d+ sec\.$/, /^You are still stunned\.$/, results_of_interest)
    end
  end

  def scripted(action, replies)
    queue = []
    allow(action).to receive(:reader).and_return(reader)
    allow(action).to receive(:game_put) { |cmd| sent << cmd; queue.concat(replies.shift || []) }
    allow(action).to receive(:clear_lines) { queue.clear }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |l| queue.unshift(l) }
    allow(action).to receive(:sleep)
    allow(action).to receive(:live_target_ids).and_return(nil)
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  def maneuver(replies, **opts)
    scripted(described_class.new(world, category: :cman, name: 'Bull Rush', target: kobold, **opts), replies)
  end

  it 'sends the reader command at the creature by id and succeeds on the result line' do
    result = maneuver([['You dip your shoulder and rush at a kobold!']]).call
    expect(sent).to eq(['cman bullrush #1234'])
    expect(result).to be_success
  end

  it 'names a refusal from the reader regex or bigshot extras' do
    # "still stunned" is a ladder rung, not an answer: the ladder waits it out
    expect(maneuver([["You can't reach a kobold!"]]).call.reason).to eq(:out_of_reach)
    expect(maneuver([['A kobold is lying down -- attempting to bull rush would be a rather awkward proposition.']]).call.reason).to eq(:awkward)
    expect(maneuver([['A little bit late for that.']]).call.reason).to eq(:already_dead)
    expect(maneuver([['Bull Rush is still in cooldown.']]).call.reason).to eq(:cooldown)
  end

  it 'times out on an answer nobody knows' do
    expect(maneuver([['You wiggle your fingers.']], timeout: 0.05).call.reason).to eq(:no_confirmation)
  end

  it 'gates in bigshot order before touching the game' do
    allow(reader).to receive(:known?).and_return(false)
    expect(maneuver([]).call.reason).to eq(:unknown_technique)
    allow(reader).to receive(:known?).and_return(true)
    me.define_singleton_method(:debuff_active?) { |n| n == 'Overexerted' }
    expect(maneuver([]).call.reason).to eq(:overexerted)
    me.define_singleton_method(:debuff_active?) { |_n| false }
    allow(reader).to receive(:affordable?).and_return(false)
    expect(maneuver([]).call.reason).to eq(:unaffordable)
    allow(reader).to receive(:affordable?).and_return(true)
    allow(reader).to receive(:available?).and_return(false)
    expect(maneuver([]).call.reason).to eq(:cooldown)
    expect(sent).to be_empty
  end

  it 'skips a self buff that is already up when asked' do
    allow(reader).to receive(:buff_active?).and_return(true)
    action = scripted(described_class.new(world, category: :cman, name: 'Burst of Swiftness', skip_if_buff: true), [])
    expect(action.call.reason).to eq(:buff_active)
  end

  it 'sends a word target as given and nothing for no target' do
    all = scripted(described_class.new(world, category: :warcry, name: 'bellow', target: 'all'), [['Roundtime: 3 sec.']])
    expect(all.call).to be_success
    bare = scripted(described_class.new(world, category: :cman, name: 'Surge of Strength'), [['Roundtime: 3 sec.']])
    expect(bare.call).to be_success
    expect(sent).to eq(['cman bellow all', 'cman surgeofstrength'])
  end

  it 'appends forcert and passes ignore_cooldown to the cman reader' do
    expect(reader).to receive(:available?).with('Bull Rush', ignore_cooldown: true).and_return(true)
    action = maneuver([['You dip your shoulder and rush at a kobold!']], forcert_count: 1, ignore_cooldown: true)
    expect(action.call).to be_success
    expect(sent).to eq(['cman bullrush #1234 forcert'])
  end

  it 'swaps once on a bow in the wrong hand and sends again' do
    action = scripted(described_class.new(world, category: :weapon, name: 'Barrage', target: kobold),
                      [['Barrage can not be used with attack as the attack type.'], ['You swap.'], ['Roundtime: 3 sec.']])
    expect(action.call).to be_success
    expect(sent).to eq(['cman barrage #1234', 'swap', 'cman barrage #1234'])
  end

  it 'picks the timeout by kind' do
    expect(described_class.new(world, category: :weapon, name: 'Barrage').instance_variable_get(:@timeout)).to eq(12)
    expect(described_class.new(world, category: :cman, name: 'Bearhug').instance_variable_get(:@timeout)).to eq(17)
    expect(described_class.new(world, category: :cman, name: 'Bull Rush').instance_variable_get(:@timeout)).to eq(2)
  end

  it 'resolves bigshot routine words, shield bash to the cman when known' do
    expect(described_class.resolve('bullrush')).to eq([:cman, 'Bull Rush'])
    expect(described_class.resolve('shield charge')).to eq([:shield, 'Shield Charge'])
    expect(described_class.resolve('nope')).to be_nil
    allow(described_class).to receive(:reader_for).with(:cman).and_return(reader)
    expect(described_class.resolve('shield bash')).to eq([:cman, 'Shield Bash'])
    allow(reader).to receive(:known?).and_return(false)
    expect(described_class.resolve('shield bash')).to eq([:shield, 'Shield Bash'])
  end
end

RSpec.describe EO::Engine::Actions::Mstrike do
  let(:me) do
    OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false,
                   stamina: 100, max_stamina: 100, moc_ranks: 40)
  end
  let(:room) { OpenStruct.new(targets: [npc(1), npc(2)]) }
  let(:world) { OpenStruct.new(me: me, room: room) }
  let(:policy) { described_class::Policy.new }
  let(:cooldowns) { [] }
  let(:sent) { [] }

  def npc(id, noun: 'kobold')
    OpenStruct.new(id: id.to_s, name: "a #{noun}", noun: noun, status: '', type: 'aggressive npc')
  end

  before do
    cds = cooldowns
    me.define_singleton_method(:debuff_active?) { |_n| false }
    me.define_singleton_method(:cooldown_active?) { |n| cds.include?(n) }
    allow(described_class).to receive(:start_regex).and_return(/^You explode into a fury of strikes/)
  end

  def mstrike(replies = [['You explode into a fury of strikes and ripostes, moving with a singular purpose and will!']], **opts)
    action = described_class.new(world, policy: policy, target: room.targets.first, **opts)
    queue = []
    allow(action).to receive(:game_put) { |cmd| sent << cmd; queue.concat(replies.shift || []) }
    allow(action).to receive(:clear_lines) { queue.clear }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |l| queue.unshift(l) }
    allow(action).to receive(:sleep)
    allow(action).to receive(:live_target_ids).and_return(nil)
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  it 'goes unfocused at the mob count and focused below it' do
    expect(mstrike.call).to be_success
    policy.mob = 3
    mstrike.call
    expect(sent).to eq(['mstrike', 'mstrike #1'])
  end

  it 'carries the unarmed attack word' do
    policy.mob = 3
    mstrike(attack: 'jab').call
    expect(sent).to eq(['mstrike jab #1'])
  end

  it 'refuses while overexerted, under 5 ranks, near a nest, or too few for an unfocused strike' do
    me.define_singleton_method(:debuff_active?) { |n| n == 'Overexerted' }
    expect(mstrike.call.reason).to eq(:overexerted)
    me.define_singleton_method(:debuff_active?) { |_n| false }
    me.moc_ranks = 4
    expect(mstrike.call.reason).to eq(:no_moc)
    me.moc_ranks = 10
    room.targets = [npc(1)]
    expect(mstrike.call.reason).to eq(:too_few)
    room.targets = [npc(1), npc(2, noun: 'nest')]
    expect(mstrike.call.reason).to eq(:nest)
  end

  it 'never focuses under 30 ranks' do
    me.moc_ranks = 10
    policy.mob = 1
    expect(mstrike.call).to be_success
    expect(sent).to eq(['mstrike'])
  end

  it 'honours the cooldown unless the profile allows it at the stamina floor' do
    cooldowns << 'Multi-Strike'
    expect(mstrike.call.reason).to eq(:cooldown)
    policy.cooldown = true
    policy.stamina_cooldown = 80
    me.stamina = 79
    expect(mstrike.call.reason).to eq(:cooldown)
    me.stamina = 80
    expect(mstrike.call).to be_success
  end

  it 'quickstrikes at the stamina floor, defaulting the floor to max stamina' do
    policy.quickstrike = true
    me.stamina = 99
    mstrike.call
    me.stamina = 100
    mstrike.call
    expect(sent).to eq(['mstrike', 'quickstrike 1 mstrike'])
  end

  it 'names a refusal and times out on silence' do
    expect(mstrike([['You do not have enough stamina to attempt this maneuver.']]).call.reason).to eq(:no_stamina)
    expect(mstrike([['You wiggle your fingers.']], timeout: 0.05).call.reason).to eq(:no_confirmation)
  end
end
