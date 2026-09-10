# frozen_string_literal: true

require_relative 'engine_helper'

TargetNpc = Struct.new(:id, :name, :noun, :status, :type, keyword_init: true)

RSpec.describe EO::Engine::Targets do
  def npc(id, name, noun: name.split.last, status: '', type: 'aggressive npc')
    TargetNpc.new(id: id.to_s, name: name, noun: noun, status: status, type: type)
  end

  let(:kobold) { npc(1, 'kobold') }
  let(:orc)    { npc(2, 'cave orc', noun: 'orc') }
  let(:rat)    { npc(3, 'giant rat', noun: 'rat') }
  let(:policy) { described_class::Policy.new(wanted: { 'kobold' => 'a', 'cave orc' => 'b' }) }

  describe '.excluded_reason' do
    it 'passes an ordinary live creature' do
      expect(described_class.excluded_reason(kobold, policy)).to be_nil
    end

    it 'rejects dead and gone' do
      expect(described_class.excluded_reason(npc(1, 'kobold', status: 'dead'), policy)).to eq(:dead)
      expect(described_class.excluded_reason(npc(1, 'kobold', status: 'gone'), policy)).to eq(:dead)
    end

    it "rejects the profile's invalid targets by name or noun" do
      p = described_class::Policy.new(invalid: ['giant rat', 'orc'])
      expect(described_class.excluded_reason(rat, p)).to eq(:invalid)
      expect(described_class.excluded_reason(orc, p)).to eq(:invalid)
      expect(described_class.excluded_reason(kobold, p)).to be_nil
    end

    it 'rejects what the game refused to TARGET' do
      p = described_class::Policy.new(untargetable: ['cave orc'])
      expect(described_class.excluded_reason(orc, p)).to eq(:untargetable)
    end

    it 'rejects appendages, summoned helpers, troll parts and animated decoys' do
      expect(described_class.excluded_reason(npc(4, 'severed arm', noun: 'arm'), policy)).to eq(:appendage)
      expect(described_class.excluded_reason(npc(5, 'writhing tentacles', noun: 'tentacles'), policy)).to eq(:appendage)
      expect(described_class.excluded_reason(npc(6, 'shadowy haze', noun: 'haze'), policy)).to eq(:summoned)
      expect(described_class.excluded_reason(npc(7, 'quickly growing troll king', noun: 'king'), policy)).to eq(:never)
      expect(described_class.excluded_reason(npc(8, 'animated statue', noun: 'statue'), policy)).to eq(:animated)
      expect(described_class.excluded_reason(npc(9, 'animated slush', noun: 'slush'), policy)).to be_nil
    end

    it 'rejects companions and familiars unless they are aggressive' do
      expect(described_class.excluded_reason(npc(10, 'wolf', type: 'companion'), policy)).to eq(:companion)
      expect(described_class.excluded_reason(npc(10, 'wolf', type: 'companion,aggressive npc'), policy)).to be_nil
    end

    it 'rejects a boon creature whose known abilities are on the ignore list, and only then' do
      boon = npc(11, 'glowing kobold', noun: 'kobold', type: 'aggressive npc,boon')
      known = { '11' => %w[extra_elem regen] }
      p = described_class::Policy.new(boons_ignore: ['regen'], boon_abilities: ->(c) { known[c.id] })
      expect(described_class.excluded_reason(boon, p)).to eq(:boon)
      expect(described_class.excluded_reason(kobold, p)).to be_nil
      unknown = npc(12, 'raging kobold', noun: 'kobold', type: 'aggressive npc,boon')
      expect(described_class.excluded_reason(unknown, p)).to be_nil
      expect(described_class.excluded_reason(boon, described_class::Policy.new)).to be_nil
    end
  end

  describe '.boon_abilities_from' do
    it 'reads the ASSESS adjectives' do
      line = 'The kobold appears to be stout, glowing and raging.'
      expect(described_class.boon_abilities_from(line)).to eq(%w[crit_padding extra_elem frenzy])
    end

    it 'is nil without a boon phrase or with unknown adjectives' do
      expect(described_class.boon_abilities_from('The kobold is too easy for the likes of you!')).to be_nil
      expect(described_class.boon_abilities_from('The kobold appears to be sleepy.')).to be_nil
    end
  end

  describe described_class::BoonCache do
    let(:boon) { npc(11, 'glowing kobold', noun: 'kobold', type: 'aggressive npc,boon') }
    let(:answers) { [] }

    it 'assesses a boon creature once and remembers its abilities by id' do
      asked = [EO::Engine::Actions::Result.new(status: :success, line: 'The kobold appears to be stout, glowing and raging.')]
      c = described_class.new(nil, assess: ->(cr) { answers << cr.id; asked.shift })
      expect(c.abilities(boon)).to eq(%w[crit_padding extra_elem frenzy])
      expect(c.abilities(boon)).to eq(%w[crit_padding extra_elem frenzy])
      expect(answers).to eq(['11'])
      expect(c.abilities(kobold)).to be_nil
      expect(answers).to eq(['11'])
    end

    it 'remembers a creature without boons, and asks again after a failed assessment' do
      asked = [EO::Engine::Actions::Result.new(status: :failed, reason: :interrupted),
               EO::Engine::Actions::Result.new(status: :failed, reason: :no_boons)]
      c = described_class.new(nil, assess: ->(cr) { answers << cr.id; asked.shift })
      expect(c.abilities(boon)).to be_nil
      expect(c.abilities(boon)).to be_nil
      expect(c.abilities(boon)).to be_nil
      expect(answers).to eq(%w[11 11])
    end

    it 'is the policy callback the ignore and flee rules consult' do
      c = described_class.new(nil, assess: ->(_cr) { EO::Engine::Actions::Result.new(status: :success, line: 'It appears to be slimy.') })
      p = EO::Engine::Targets::Policy.new(boons_ignore: ['regen'], boon_abilities: c.to_proc)
      expect(EO::Engine::Targets.excluded_reason(boon, p)).to eq(:boon)
    end
  end

  describe 'wanted, rank and routine' do
    it 'matches the targets list by name or noun, anchored' do
      expect(described_class.wanted?(kobold, policy)).to be true
      expect(described_class.wanted?(orc, policy)).to be true
      expect(described_class.wanted?(rat, policy)).to be false
      expect(described_class.wanted?(npc(13, 'kobold shaman', noun: 'shaman'), policy)).to be false
    end

    it 'wants everything when the list is empty' do
      expect(described_class.wanted?(rat, described_class::Policy.new)).to be true
      expect(described_class.routine_for(rat, described_class::Policy.new)).to eq('a')
    end

    it 'ranks by list position, unlisted last, and names the routine letter' do
      expect(described_class.rank(kobold, policy)).to eq(0)
      expect(described_class.rank(orc, policy)).to eq(1)
      expect(described_class.rank(rat, policy)).to eq(Float::INFINITY)
      expect(described_class.routine_for(orc, policy)).to eq('b')
      expect(described_class.routine_for(rat, policy)).to eq('a')
    end

    it 'accepts regex fragments as keys, the way the targets setting allows' do
      p = described_class::Policy.new(wanted: { 'kobold|cave orc' => 'c' })
      expect(described_class.routine_for(orc, p)).to eq('c')
    end
  end

  describe '.candidates and .fightable_count' do
    it 'drops excluded and unwanted creatures and orders by rank, then by roster order' do
      orc2 = npc(20, 'cave orc', noun: 'orc')
      roster = [rat, orc, npc(21, 'kobold', status: 'dead'), orc2, kobold]
      expect(described_class.candidates(roster, policy).map(&:id)).to eq(%w[1 2 20])
      expect(described_class.fightable_count(roster, policy)).to eq(4)
    end
  end

  describe '.choose' do
    it 'keeps the current target while it is valid' do
      expect(described_class.choose([orc, kobold], policy, current: orc)).to equal(orc)
    end

    it 'drops a current target that died or left the roster' do
      expect(described_class.choose([kobold], policy, current: orc)).to equal(kobold)
      dead = npc(2, 'cave orc', noun: 'orc', status: 'dead')
      expect(described_class.choose([dead, kobold], policy, current: dead)).to equal(kobold)
    end

    it 'with priority, only a strictly better rank interrupts the current target' do
      expect(described_class.choose([orc, kobold], policy, current: orc, priority: true)).to equal(kobold)
      other_orc = npc(20, 'cave orc', noun: 'orc')
      expect(described_class.choose([other_orc, orc], policy, current: orc, priority: true)).to equal(orc)
      expect(described_class.choose([rat, orc], policy, current: orc, priority: true)).to equal(orc)
    end

    it 'is nil with nothing to fight' do
      expect(described_class.choose([rat], policy)).to be_nil
      expect(described_class.choose([], policy, current: kobold)).to be_nil
    end
  end
end
