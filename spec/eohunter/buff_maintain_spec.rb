# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Behaviors::Maintain, 'combat buff policy' do
  let(:clock) { OpenStruct.new(now: 100.0) }
  let(:wall_clock) { OpenStruct.new(now: Time.at(10_000)) }
  let(:spell) do
    double('Spell', name: 'Elemental Defense II', active?: false, known?: true, affordable?: true,
                    mana_cost: 6, last_cast: Time.at(0), type: 'defense', time_per: 120)
  end
  let(:me) do
    double('Me', name: 'Testcaster', mana: 100, in_rt?: false, in_cast_rt?: false,
                 spell_active?: false, effect_active?: false, cooldown_active?: false)
  end
  let(:world) { OpenStruct.new(me: me, spell: { 406 => spell }) }
  let(:raw) { { 'enabled' => true, 'spells' => { 406 => 'recast' } } }
  let(:buffs) { EO::Engine::BuffPolicy::Coordinator.new(policy: EO::Engine::BuffPolicy::Policy.new(raw), clock: clock) }
  let(:maintain) do
    described_class.new(policy: EO::Engine::Maintain::Policy.new(signs: ['406']), buffs: buffs, clock: wall_clock)
  end
  let(:cast) { double('Cast', call: EO::Engine::Actions::Result.new(status: :success)) }

  before { allow(EO::Engine::Actions::Cast).to receive(:new).and_return(cast) }
  after { EO::Engine::Events.reset! }

  it 'uses the existing casting action once and waits for observation before retrying' do
    expect(maintain.wants_control?(world)).to be true
    maintain.tick(world)
    5.times do
      expect(maintain.wants_control?(world)).to be true
      maintain.tick(world)
    end
    expect(cast).to have_received(:call).once
    expect(EO::Engine::Actions::Cast).to have_received(:new).with(world, spell: 406, target: 'Testcaster').once
    clock.now += 3
    maintain.tick(world)
    expect(cast).to have_received(:call).twice
    clock.now += 3
    expect(maintain.wants_control?(world)).to be false
    expect(buffs.rest_reason(world)).to eq(EO::Engine::BuffPolicy::FIELD_REASON)
  end

  it 'honors ignore/warn overrides even when the same spell is in legacy signs' do
    raw['spells'][406] = 'ignore'
    expect(maintain.wants_control?(world)).to be false
    maintain.tick(world)
    expect(cast).not_to have_received(:call)
  end

  it 'does not start another restoration while a previous cast awaits confirmation' do
    raw['spells'][503] = 'recast'
    world.spell[503] = spell
    maintain.tick(world)
    maintain.tick(world)
    expect(cast).to have_received(:call).once
    expect(buffs.assess(world).map(&:state)).to eq(%w[pending recast])
  end

  it 'does not spend retry attempts or send commands during roundtime' do
    allow(me).to receive(:in_rt?).and_return(true)
    10.times { maintain.tick(world); clock.now += 3 }
    expect(cast).not_to have_received(:call)
    expect(buffs.assess(world).first.state).to eq('recast')
    allow(me).to receive(:in_rt?).and_return(false)
    maintain.tick(world)
    expect(cast).to have_received(:call).once
  end

  # A spell the character cannot cast at all - not enough mana for it, and
  # no wracking configured - is a real failure to restore, so the attempts
  # are spent and recovery is asked for.
  it 'respects existing casting gates instead of hammering a blocked spell forever' do
    allow(spell).to receive(:affordable?).and_return(false)
    2.times { maintain.tick(world); clock.now += 3 }
    expect(cast).not_to have_received(:call)
    expect(buffs.rest_reason(world)).to eq(EO::Engine::BuffPolicy::FIELD_REASON)
  end

  # A cooldown is temporary: the spell is known, affordable and wanted, it
  # simply cannot be cast for another second. Counting the attempt before
  # the gate spent the recovery budget on checks that sent nothing, so two
  # ticks inside one cooldown exhausted it and asked for a field or town
  # recovery that was never needed.
  it 'does not spend a recovery attempt while the spell is only cooling' do
    # cast a moment ago on the same clock the gate reads
    allow(spell).to receive(:last_cast).and_return(wall_clock.now)

    2.times { maintain.tick(world); clock.now += 3 }
    expect(cast).not_to have_received(:call)
    expect(buffs.rest_reason(world)).to be_nil # nothing has actually failed

    # the cooldown passes and the cast goes out on its own
    wall_clock.now += 5
    maintain.tick(world)
    expect(cast).to have_received(:call).once
  end

  it 'keeps the legacy signs behavior unchanged without a coordinator' do
    original = described_class.new(policy: EO::Engine::Maintain::Policy.new(signs: ['406']), clock: wall_clock)
    expect(original.wants_control?(world)).to be true
    original.tick(world)
    expect(cast).to have_received(:call).once
  end

  it 'restores through the real Cast action using a player target accepted by the game' do
    allow(me).to receive_messages(name: 'Testcaster', dead?: false, muckled?: false)
    allow(EO::Engine::Actions::Cast).to receive(:new).and_call_original
    stub_const('Spell', Class.new { def self.[](_id); end })
    allow(Spell).to receive(:[]).with(406).and_return(spell)
    # Replay the live protocol refusal. The game does not resolve "self"
    # as a player name; a named character is an accepted CAST target.
    allow(spell).to receive(:cast) do |target, *|
      if target == 'Testcaster'
        allow(spell).to receive(:active?).and_return(true)
        'Cast Roundtime 3 Seconds.'
      else
        'Cast at what?'
      end
    end
    result = maintain.tick(world)
    expect(result).to be_success
    expect(buffs.missing_required(world)).to be_empty
    expect(buffs.rest_reason(world)).to be_nil
  end

  context 'with optional bulk spell-up' do
    let(:command) { double('Command', call: EO::Engine::Actions::Result.new(status: :success)) }
    let(:status_result) { EO::Engine::Actions::Result.new(status: :success, reason: :available) }
    let(:status_query) { double('Mana status', call: status_result) }

    before do
      raw['mana_spellup_at'] = 2
      raw['spells'][503] = 'recast'
      world.spell[503] = double('Second spell', name: 'Thurfel Ward', active?: false, known?: true,
                                              affordable?: true, type: 'defense', time_per: 120)
      allow(EO::Engine::Actions::Command).to receive(:new).and_return(command)
      allow(EO::Engine::Actions::ManaSpellupStatus).to receive(:new).and_return(status_query)
    end

    it 'schedules one bulk command and falls back to individual casts without spending their attempts' do
      expect(maintain.wants_control?(world)).to be true
      maintain.tick(world)
      5.times { maintain.tick(world) }
      expect(EO::Engine::Actions::Command).to have_received(:new).with(world, command: 'mana spellup').once
      expect(cast).not_to have_received(:call)
      expect(buffs.missing_required(world)).to eq([406, 503])
      2.times { clock.now += 3; maintain.tick(world) }
      expect(cast).to have_received(:call).twice
      expect(command).to have_received(:call).once
    end

    it 'permits another bulk spell-up on a later loss after verified restoration' do
      2.times { maintain.tick(world) }
      world.spell.each_value { |entry| allow(entry).to receive(:active?).and_return(true) }
      expect(buffs.missing_required(world)).to be_empty
      world.spell.each_value { |entry| allow(entry).to receive(:active?).and_return(false) }
      expect(buffs.assess(world).map(&:state)).to eq(%w[spellup_check spellup_check])
      2.times { maintain.tick(world) }
      expect(command).to have_received(:call).twice
      expect(status_query).to have_received(:call).twice
      expect(cast).not_to have_received(:call)
    end

    it 'keeps bulk disabled after failed confirmation, even after native recovery and a new loss' do
      2.times { maintain.tick(world) }
      clock.now += 3
      maintain.tick(world)
      world.spell.each_value { |entry| allow(entry).to receive(:active?).and_return(true) }
      expect(buffs.missing_required(world)).to be_empty
      world.spell.each_value { |entry| allow(entry).to receive(:active?).and_return(false) }
      maintain.tick(world)
      expect(command).to have_received(:call).once
      expect(cast).to have_received(:call).twice
    end

    it 'uses individual casts for two missing buffs and bulk at the configured three-buff threshold' do
      raw['mana_spellup_at'] = 3
      expect(buffs.assess(world).map(&:state)).to eq(%w[recast recast])
      raw['spells'][414] = 'recast'
      world.spell[414] = spell
      # Rebuild the immutable policy after changing the profile configuration.
      three = EO::Engine::BuffPolicy::Coordinator.new(policy: EO::Engine::BuffPolicy::Policy.new(raw), clock: clock)
      expect(three.assess(world).map(&:state)).to eq(%w[spellup_check spellup_check spellup_check])
    end

    it 'tries bulk at zero mana but requests recovery if it does not restore effects' do
      world.spell.each_value { |entry| allow(entry).to receive(:affordable?).and_return(false) }
      expect(buffs.rest_reason(world)).to be_nil
      2.times { maintain.tick(world) }
      clock.now += 3
      expect(buffs.rest_reason(world)).to eq(EO::Engine::BuffPolicy::FIELD_REASON)
      expect(cast).not_to have_received(:call)
    end

    it 'honors cast roundtime before reserving or sending a bulk attempt' do
      allow(me).to receive(:in_cast_rt?).and_return(true)
      5.times { maintain.tick(world) }
      expect(command).not_to have_received(:call)
      allow(me).to receive(:in_cast_rt?).and_return(false)
      2.times { maintain.tick(world) }
      expect(command).to have_received(:call).once
    end

    it 'queries first and spends no spell-up when the daily count is exhausted' do
      status_result.reason = :exhausted
      maintain.tick(world)
      expect(cast).not_to have_received(:call)
      5.times { maintain.tick(world) }
      expect(status_query).to have_received(:call).once
      expect(command).not_to have_received(:call)
      expect(cast).to have_received(:call).once
    end

    it 'falls back on an unconfirmed query without treating it as permission to spend a use' do
      status_result.status = :timeout
      status_result.reason = :no_confirmation
      2.times { maintain.tick(world) }
      expect(command).not_to have_received(:call)
      expect(cast).to have_received(:call).once
    end

    it 'rechecks an exhausted count on a later loss after the short cache expires' do
      status_result.reason = :exhausted
      maintain.tick(world)
      world.spell.each_value { |entry| allow(entry).to receive(:active?).and_return(true) }
      buffs.assess(world)
      clock.now += 61
      world.spell.each_value { |entry| allow(entry).to receive(:active?).and_return(false) }
      status_result.reason = :available
      2.times { maintain.tick(world) }
      expect(status_query).to have_received(:call).twice
      expect(command).to have_received(:call).once
    end

    it 'does not count unknown, offensive or explicitly return-managed spells toward the threshold' do
      raw['spells'][503] = 'field'
      expect(buffs.assess(world).map(&:state)).to eq(%w[recast field])
    end
  end
end
