# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'combat actions' do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false) }
  let(:world) { OpenStruct.new(me: me) }
  let(:kobold) { OpenStruct.new(id: '1234', name: 'kobold', noun: 'kobold') }
  let(:sent) { [] }

  # A scripted game for the ladder: each send answers with the next reply list.
  def script(action, replies)
    queue = []
    allow(action).to receive(:game_send) { |cmd| sent << cmd; queue.concat(replies.shift || []); queue.first || :no_response }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |line| queue.unshift(line) }
    allow(action).to receive(:sleep)
    allow(action).to receive(:live_target_ids).and_return(nil)
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  describe EO::Engine::Actions::Attack do
    before do
      # the combat defs are Lich's; here a stand-in with the two shapes that matter
      allow(described_class).to receive(:initiation_regex).and_return(
        /You(?: take aim and)? swing .+? at (?<target>[^!]+)!|You(?: take aim and)? fire .+? at (?<target>[^!]+)!/
      )
    end

    it 'sends ATTACK #id and confirms on the initiation line' do
      action = script(described_class.new(world, target: kobold), [['You swing a broadsword at a kobold!', 'A clean miss.']])
      result = action.call
      expect(sent).to eq(['attack #1234'])
      expect(result).to be_success
      expect(result.line).to eq('You swing a broadsword at a kobold!')
    end

    it 'takes another verb' do
      action = script(described_class.new(world, target: kobold, verb: 'fire'), [['You take aim and fire a bow at a kobold!']])
      expect(action.call).to be_success
      expect(sent).to eq(['fire #1234'])
    end

    it 'names the refusal when no swing went out' do
      action = script(described_class.new(world, target: kobold), [['What were you referring to?']])
      result = action.call
      expect(result).to be_failed
      expect(result.reason).to eq(:referent_missing)
    end

    it 'names a missing weapon' do
      action = script(described_class.new(world, target: kobold, verb: 'fire'), [['Fire what?']])
      expect(action.call.reason).to eq(:weapon_missing)
    end

    it 'times out when the game answers with something the defs do not know' do
      action = script(described_class.new(world, target: kobold, timeout: 0.05), [['You wiggle your fingers.']])
      expect(action.call.reason).to eq(:no_confirmation)
    end

    it 'refuses to act while dead, muckled or without a target' do
      me[:dead?] = true
      expect(described_class.new(world, target: kobold).call.reason).to eq(:dead)
      me[:dead?] = false
      me[:muckled?] = true
      expect(described_class.new(world, target: kobold).call.reason).to eq(:muckled)
      me[:muckled?] = false
      expect(described_class.new(world, target: nil).call.reason).to eq(:no_target)
    end

    it 'waits out cast roundtime before swinging' do
      action = script(described_class.new(world, target: kobold), [['You swing a broadsword at a kobold!']])
      waited = []
      allow(action).to receive(:game_wait_rt) { |kind| waited << kind }
      expect(action.call).to be_success
      expect(waited).to eq(%i[hard cast])
    end
  end

  describe EO::Engine::Actions::Cast do
    let(:spell) { double('Spell', known?: true, affordable?: true) }

    before { stub_const('Spell', Class.new { def self.[](_n); end }) }

    def cast(**opts)
      allow(Spell).to receive(:[]).with(1030).and_return(spell)
      action = described_class.new(world, spell: 1030, **opts)
      allow(action).to receive(:live_target_ids).and_return(nil)
      allow(action).to receive(:sleep)
      action
    end

    it 'casts at the target by id and succeeds on the cast roundtime line' do
      expect(spell).to receive(:cast).with('#1234', nil, nil, force_stance: nil).and_return('Cast Roundtime 3 Seconds.')
      result = cast(target: kobold).call
      expect(result).to be_success
      expect(result.line).to eq('Cast Roundtime 3 Seconds.')
    end

    it 'casts on a named player without treating them as a hostile target id' do
      expect(spell).to receive(:cast).with('Skooshii', nil, nil, force_stance: nil).and_return('Cast Roundtime 3 Seconds.')
      action = cast(target: 'Skooshii')
      allow(action).to receive(:live_target_ids).and_return([])

      expect(action.call).to be_success
    end

    it 'routes evoke / channel / cast words to the force_* forms' do
      expect(spell).to receive(:force_evoke).with('#1234', '', force_stance: nil).and_return('Cast Roundtime 3 Seconds.')
      expect(cast(target: kobold, extra: 'evoke').call).to be_success
    end

    it 'incants with no target when asked, and still incants with a target in hand' do
      expect(spell).to receive(:force_incant).with(nil, force_stance: nil).twice.and_return('Cast Roundtime 3 Seconds.')
      expect(cast(incant: true).call).to be_success
      expect(cast(incant: true, target: kobold).call).to be_success
    end

    it 'classifies blocked, no target, cannot prepare, no mana and fizzle' do
      {
        'Be at peace my child, there is no need for spells of war in here.' => :blocked,
        'Cast at what?'                                                     => :no_target,
        "You can't think clearly enough to prepare a spell!"                => :cannot_prepare,
        "But you don't have any mana!"                                      => :no_mana,
        'Your magic fizzles ineffectually.'                                 => :fizzled
      }.each do |line, reason|
        allow(spell).to receive(:cast).and_return(line)
        expect(cast(target: kobold).call.reason).to eq(reason)
      end
    end

    it 'retries a hindrance up to three times, then fails :hindrance' do
      allow(spell).to receive(:cast).and_return('[Spell Hindrance for Full Plate is 30 percent.]')
      result = cast(target: kobold).call
      expect(result.reason).to eq(:hindrance)
      expect(spell).to have_received(:cast).exactly(3).times
    end

    it 'succeeds after a hindrance clears' do
      allow(spell).to receive(:cast).and_return('[Spell Hindrance for Full Plate is 30 percent.]', 'Cast Roundtime 3 Seconds.')
      expect(cast(target: kobold).call).to be_success
    end

    it 'fails :cast_refused when Spell#cast returns false' do
      allow(spell).to receive(:cast).and_return(false)
      expect(cast(target: kobold).call.reason).to eq(:cast_refused)
    end

    it 'refuses an unknown or unaffordable spell before touching the game' do
      allow(spell).to receive(:known?).and_return(false)
      expect(cast(target: kobold).call.reason).to eq(:unknown_spell)
      allow(spell).to receive(:known?).and_return(true)
      allow(spell).to receive(:affordable?).and_return(false)
      expect(cast(target: kobold).call.reason).to eq(:unaffordable)
    end
  end
end
