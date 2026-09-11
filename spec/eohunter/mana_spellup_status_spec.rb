# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Actions::ManaSpellupStatus do
  let(:world) { OpenStruct.new(me: OpenStruct.new(dead?: false)) }

  def query(line)
    action = described_class.new(world)
    queue = []
    allow(action).to receive(:game_send).with('mana') do
      queue.concat(['Maximum Mana Points: 293', line])
      queue.first
    end
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:sleep)
    tick = 0
    allow(action).to receive(:clock_now) { tick += 0.1 }
    action.call
  end

  it 'reads the real MANA response after preceding output and reports availability' do
    result = query('    You have used the MANA SPELLUP ability 2 out of 6 times for today.  The available uses will reset in 8 hours and 33 minutes.')
    expect(result).to be_success
    expect(result.reason).to eq(:available)
    expect(result).to be_acted
  end

  it 'reports zero remaining uses without dispatching a spell-up' do
    expect(query('You have used the MANA SPELLUP ability 6 out of 6 times for today.').reason).to eq(:exhausted)
  end

  it 'accepts a fresh daily reset count' do
    expect(query('You have used the MANA SPELLUP ability 0 out of 6 times for today.').reason).to eq(:available)
  end

  it 'does not trust inconsistent counts' do
    expect(query('You have used the MANA SPELLUP ability 7 out of 6 times for today.').reason).to eq(:unknown_allowance)
  end

  it 'bounds missing or changed-format output instead of assuming availability' do
    result = query('No matching ability information.')
    expect(result.status).to eq(:timeout)
    expect(result.reason).to eq(:no_confirmation)
  end
end
