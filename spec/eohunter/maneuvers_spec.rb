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
    allow(action).to receive(:game_send) { |cmd| sent << cmd; queue.concat(replies.shift || []); queue.first || :no_response }
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

  it 'runs a recovery technique while in the state it escapes, and refuses the others' do
    me[:muckled?] = true
    me[:webbed?] = true
    escape = scripted(described_class.new(world, category: :feat, name: 'escapeartist', escapes: %i[webbed bound]), [['Roundtime: 3 sec.']])
    expect(escape.call).to be_success
    expect(sent).to eq(['cman escapeartist'])

    me[:stunned?] = true
    stunned = scripted(described_class.new(world, category: :feat, name: 'escapeartist', escapes: %i[webbed bound]), [])
    expect(stunned.call.reason).to eq(:muckled)
    me[:stunned?] = false
    plain = scripted(described_class.new(world, category: :cman, name: 'Bull Rush', target: kobold), [])
    expect(plain.call.reason).to eq(:muckled)
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

  # Warcry.command has no usage table: it sends PSMS.name_normal(name) as
  # given (warcry.rb 208), unlike CMan.command which resolves :usage. A
  # long name therefore went on the wire as `warcry seanettes_shout`, and
  # Maintain names the Shout exactly that way (maintain.rb 647) - so the
  # one warcry the engine sends on its own was the one that could not land.
  describe 'a warcry named in full' do
    # Lich's own lookup table and the two methods that read it.
    let(:warcry_reader) do
      table = { 'seanettes_shout' => { long_name: 'seanettes_shout', short_name: 'shout' },
                'carns_cry'       => { long_name: 'carns_cry', short_name: 'cry' } }
      stub_const('Lich::Gemstone::PSMS', Module.new do
        define_singleton_method(:name_normal) { |n| n.to_s.downcase.gsub(/[^a-z0-9 ]/, '').gsub(/\s+/, '_') }
        define_singleton_method(:find_name) do |name, _type|
          normal = name_normal(name)
          table.values.find { |h| h[:long_name] == normal || h[:short_name] == normal }
        end
      end)
      double('Warcry', known?: true, affordable?: true, available?: true, buff_active?: false).tap do |r|
        # verbatim, as Lich builds it
        allow(r).to receive(:command) { |name, target, **| "warcry #{::Lich::Gemstone::PSMS.name_normal(name)}#{target.to_s.empty? ? '' : " #{target}"}" }
        allow(r).to receive(:results_regex) { Regexp.union(/You let loose an echoing shout!/, /^Roundtime: \d+ sec\.$/) }
      end
    end

    def warcry(name)
      action = described_class.new(world, category: :warcry, name: name)
      queue = []
      allow(action).to receive(:reader).and_return(warcry_reader)
      allow(action).to receive(:game_send) { |cmd| sent << cmd; queue.concat([['You let loose an echoing shout!']].shift || []); queue.first || :no_response }
      allow(action).to receive(:next_line) { queue.shift }
      allow(action).to receive(:unread_line) { |l| queue.unshift(l) }
      allow(action).to receive(:sleep)
      allow(action).to receive(:live_target_ids).and_return(nil)
      tick = 0.0
      allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
      action
    end

    it 'sends the short word the game accepts, not the normalized long name' do
      expect(warcry("Seanette's Shout").call).to be_success
      expect(sent).to eq(['warcry shout'])
    end

    it 'leaves a name already given short alone' do
      warcry('shout').call
      expect(sent).to eq(['warcry shout'])
    end

    it 'passes an unknown name through rather than raising' do
      warcry('Not A Warcry').call
      expect(sent).to eq(['warcry not_a_warcry'])
    end
  end

  # An assault runs a variable number of rounds - one, or five and more -
  # so its read is bounded by the technique rather than a guessed span:
  # Lich loops on the completion line with 12 s only as a backstop
  # (weapon.rb 309-320). The engine's membership test compared the routine
  # word against @name, which resolve() has already turned into the long
  # name, so 'Guardant Thrusts' never matched 'gthrusts' and the longest
  # assault in the set read for 2 s instead of 12.
  describe 'the assault read window' do
    def timeout_for(name, category: :weapon)
      described_class.new(world, category: category, name: name, target: kobold).send(:default_timeout)
    end

    it 'gives every assault the assault window, by the name the reader uses' do
      %w[Barrage Flurry Fury Pummel Thrash].each do |name|
        expect(timeout_for(name)).to eq(described_class::ASSAULT_TIMEOUT)
      end
      # the one the routine word never matched
      expect(timeout_for('Guardant Thrusts')).to eq(described_class::ASSAULT_TIMEOUT)
    end

    it 'gives bearhug its own longer window and everything else the short one' do
      expect(timeout_for('Bearhug', category: :cman)).to eq(described_class::BEARHUG_TIMEOUT)
      expect(timeout_for('Charge')).to eq(described_class::TIMEOUT)
      expect(timeout_for('Bull Rush', category: :cman)).to eq(described_class::TIMEOUT)
    end

    it 'reads Lich\'s own :assault type when the table is there' do
      stub_const('Lich::Gemstone::PSMS', Module.new do
        define_singleton_method(:find_name) do |name, _type|
          name.to_s.casecmp('Guardant Thrusts').zero? ? { type: :assault } : nil
        end
      end)
      expect(timeout_for('Guardant Thrusts')).to eq(described_class::ASSAULT_TIMEOUT)
    end

    it 'falls back to the names when the table cannot be read' do
      stub_const('Lich::Gemstone::PSMS', Module.new do
        define_singleton_method(:find_name) { |_n, _t| raise 'no table here' }
      end)
      expect(timeout_for('Guardant Thrusts')).to eq(described_class::ASSAULT_TIMEOUT)
      expect(timeout_for('Charge')).to eq(described_class::TIMEOUT)
    end
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
    allow(action).to receive(:game_send) { |cmd| sent << cmd; queue.concat(replies.shift || []); queue.first || :no_response }
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
