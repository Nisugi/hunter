# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Behaviors::Rest, 'Field/Town Rest' do
  let(:clock) { OpenStruct.new(now: 100.0) }
  let(:me) do
    OpenStruct.new(fxp_pct: 100, mana_pct: 100, spirit: 10, stamina_pct: 100,
                   encumbrance_pct: 0, dead?: false, in_rt?: false, in_cast_rt?: false)
  end
  let(:world) { OpenStruct.new(me: me, room: OpenStruct.new(id: 200)) }
  let(:raw) do
    { 'resting_room_id' => 100, 'hunting_room_id' => 200, 'return_waypoint_ids' => '80',
      'rallypoint_room_ids' => '90', 'fog_return' => 1, 'encumbered' => 60, 'oom' => 20,
      'resting_commands' => 'town-ready', 'resting_scripts' => 'sell, herbs',
      'hunting_prep_commands' => 'town-prep', 'field_rest_room_id' => 50,
      'field_return_waypoint_ids' => '40', 'field_rallypoint_room_ids' => '60',
      'field_rest_commands' => 'sit', 'field_rest_scripts' => 'field-buff',
      'field_hunting_prep_commands' => 'stand', 'field_rest_timeout_seconds' => 30 }
  end
  let(:profile) { EO::Engine::Profile.new(raw) }
  let(:policy) { profile.rest_policy }
  let(:scripts) { double('Scripts', start: true, running?: false) }
  let(:trips) { [] }
  let(:fogged) { [] }
  let(:sent) { [] }
  let(:rest) do
    described_class.new(policy: policy, clock: clock, scripts: scripts, stance: ->(*) { true },
                        travel: ->(room) { trips << room; world.room.id = room; true },
                        fog: ->(pol, *) { fogged << pol.resting_room; true })
  end

  before do
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:send_through_ladder) { |_a, command| sent << command; 'ok' }
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:sleep)
  end

  after { EO::Engine::Events.reset!; EO::Engine::Travel.reset! }

  def until_phase(phase, limit = 100)
    limit.times do
      rest.tick(world)
      return if rest.phase == phase
    end
    raise "expected #{phase}; got #{rest.phase}"
  end

  def begin_rest
    expect(rest.wants_control?(world)).to be true
    rest.tick(world)
  end

  it 'recovers fried at the field site with only field scripts and no town fog/routes' do
    begin_rest
    expect(rest.rest_site).to eq(:field)
    until_phase(:resting)
    expect(trips).to eq([40, 50])
    expect(fogged).to be_empty
    expect(scripts).to have_received(:start).with('field-buff', nil).once
    expect(scripts).not_to have_received(:start).with('sell', anything)
    expect(sent).to eq(['sit'])
    me.fxp_pct = 0
    until_phase(:hunting)
    expect(trips).to eq([40, 50, 60, 200])
    expect(sent).to eq(%w[sit stand])
    expect(policy.resting_room).to eq(100)
    expect(policy.fog_return).to eq(1)
  end

  it 'uses town for persistent encumbrance even when the mind is full' do
    me.encumbrance_pct = 70
    rest.wants_control?(world)
    clock.now += 5
    begin_rest
    expect(rest.rest_site).to eq(:town)
    expect(rest.reason).to eq('encumbered.')
    until_phase(:resting)
    expect(trips).to eq([80, 100])
    expect(fogged).to eq([100])
    expect(scripts).to have_received(:start).with('sell', nil).once
    expect(scripts).to have_received(:start).with('herbs', nil).once
    expect(scripts).not_to have_received(:start).with('field-buff', anything)
  end

  it 'starts at field rest using only its departure commands and route' do
    world.room.id = 50
    me.fxp_pct = 0
    rest.start!(world)
    until_phase(:hunting)
    expect(sent).to eq(['stand'])
    expect(trips).to eq([60, 200])
    expect(fogged).to be_empty
  end

  it 'reroutes new wounds before departure from field rest' do
    begin_rest
    until_phase(:resting)
    me.fxp_pct = 0
    until_phase(:hunting_prep)
    policy.wounded = -> { true }
    rest.tick(world)
    expect(rest.rest_site).to eq(:town)
    expect(rest.reason).to eq('wounded.')
    until_phase(:resting)
    expect(world.room.id).to eq(100)
  end

  it 'lets a field script finish before escalating to town' do
    begin_rest
    until_phase(:resting)
    allow(scripts).to receive(:running?).with('field-buff').and_return(true)
    policy.wounded = -> { true }
    rest.tick(world)
    expect(rest.rest_site).to eq(:field)
    allow(scripts).to receive(:running?).with('field-buff').and_return(false)
    rest.tick(world)
    expect(rest.rest_site).to eq(:town)
  end

  it 'falls back to town after field routing exhausts existing travel retries' do
    begin_rest
    rest.instance_variable_set(:@travel, ->(room) { room == 100 ? (world.room.id = room; true) : false })
    150.times do
      clock.now += 61
      rest.tick(world)
      break if rest.rest_site == :town
    end
    expect(rest.rest_site).to eq(:town)
    expect(rest.reason).to eq('field refuge unreachable.')
    expect(scripts).not_to have_received(:start)
  end

  it 'escalates at field rest when settled weight needs town service' do
    begin_rest
    until_phase(:resting)
    me.encumbrance_pct = 70
    rest.tick(world)
    clock.now += 5
    rest.tick(world)
    expect(rest.rest_site).to eq(:town)
    expect(rest.phase).to eq(:leave)
    until_phase(:resting)
    expect(world.room.id).to eq(100)
  end

  it 'escalates after a bounded field recovery interval, without bouncing back to field' do
    begin_rest
    until_phase(:resting)
    clock.now += 31
    rest.tick(world)
    expect(rest.rest_site).to eq(:town)
    expect(rest.reason).to eq('field recovery timed out.')
    until_phase(:resting)
    expect(world.room.id).to eq(100)
    rest.tick(world)
    expect(rest.rest_site).to eq(:town)
  end

  it 'allows Engage out-of-mana recovery in the field but forces unknown failures to town' do
    me.fxp_pct = 0
    rest.rest!('out of mana')
    begin_rest
    expect(rest.rest_site).to eq(:field)
    rest.request_return!('controller-directed return')
    expect(rest.rest_site).to eq(:town)
    expect(rest.phase).to eq(:leave)
  end

  it 'chooses town immediately for wounds by default' do
    policy.wounded = -> { true }
    begin_rest
    expect(rest.reason).to eq('wounded.')
    expect(rest.rest_site).to eq(:town)
  end

  it 'supports an explicit service/supplies condition and waits until it is resolved' do
    required = true
    policy.sites = EO::Engine::Rest::Sites.new(room: 50, town_required: -> { required })
    begin_rest
    expect(rest.reason).to eq('town service required.')
    until_phase(:resting)
    me.fxp_pct = 0
    rest.tick(world)
    expect(rest.phase).to eq(:resting)
    required = false
    clock.now += 31
    rest.tick(world)
    expect(rest.phase).to eq(:hunting_prep)
  end

  it 'waits for the selected script instead of starting the next service concurrently' do
    policy.wounded = -> { true }
    begin_rest
    allow(scripts).to receive(:running?).with('sell').and_return(true)
    # A pre-existing sell script follows the legacy kill/restart contract.
    allow(scripts).to receive(:kill)
    allow(rest).to receive(:sleep)
    15.times { rest.tick(world) }
    expect(scripts).to have_received(:start).with('sell', nil).once
    expect(scripts).not_to have_received(:start).with('herbs', anything)
    allow(scripts).to receive(:running?).with('sell').and_return(false)
    until_phase(:resting)
    expect(scripts).to have_received(:start).with('herbs', nil).once
  end

  it 'never runs location-specific services after an unverified arrival' do
    begin_rest
    until_phase(:resting_prep)
    world.room.id = 99
    rest.tick(world)
    expect(rest.phase).to eq(:service_failed)
    expect(scripts).not_to have_received(:start)
  end

  it 'fails explicitly when a required service cannot start' do
    allow(scripts).to receive(:start).and_return(nil)
    begin_rest
    until_phase(:service_failed)
    expect(rest.resting?).to be true
  end

  it 'does not run services or resume hunting when town is unreachable' do
    rest.rest!('manual town return')
    begin_rest
    rest.instance_variable_set(:@travel, ->(*) { false })
    150.times do
      clock.now += 61
      rest.tick(world)
      break if rest.phase == :service_failed
    end
    expect(rest.phase).to eq(:service_failed)
    expect(scripts).not_to have_received(:start)
  end

  it 'can stop at town after recovery instead of automatically hunting again' do
    raw['after_town_rest'] = 'stop'
    rest.rest!('manual town return')
    begin_rest
    until_phase(:resting)
    me.fxp_pct = 0
    seen = []
    EO::Engine::Events.on(:town_rest_complete) { seen << true }
    until_phase(:town_complete)
    expect(seen).to eq([true])
    expect(trips).to eq([80, 100])
  end

  it 'leaves single-rest profiles on their existing room and routines' do
    raw.delete('field_rest_room_id')
    begin_rest
    until_phase(:resting)
    expect(trips).to eq([80, 100])
    expect(scripts).to have_received(:start).with('sell', nil)
  end
end

RSpec.describe EO::Engine::Profile, 'rest destination validation' do
  let(:valid) { { 'resting_room_id' => 100, 'field_rest_room_id' => 50 } }

  it 'rejects invalid settings while loading the profile, before any travel' do
    [{ 'field_rest_room_id' => 'somewhere' }, { 'resting_room_id' => nil },
     { 'field_rest_for' => 'encumbered' }, { 'field_rest_timeout_seconds' => -1 },
     { 'encumbrance_grace_seconds' => 'nope' }, { 'after_town_rest' => 'whatever' },
     { 'field_return_waypoint_ids' => 'bad' }].each do |bad|
      expect { described_class.new(valid.merge(bad)) }.to raise_error(ArgumentError)
    end
    expect { described_class.new(valid.merge('field_rest_room_id' => 'u999')) }.to raise_error(ArgumentError, /resolved/)
    expect { described_class.new(valid.merge('field_return_waypoint_ids' => 'u999')) }.to raise_error(ArgumentError, /resolved/)
  end

  it 'does not silently apply dual destinations to coordinated groups or LAB' do
    profile = described_class.new(valid)
    expect(profile.validate_rest_mode!(nil)).to be true
    expect { profile.validate_rest_mode!('head') }.to raise_error(ArgumentError, /solo/)
    expect { profile.validate_rest_mode!('tail') }.to raise_error(ArgumentError, /solo/)
    expect { profile.validate_rest_mode!(nil, controlled: true) }.to raise_error(ArgumentError, /solo/)
    expect { profile.validate_rest_mode!(nil, bounty: true) }.to raise_error(ArgumentError, /solo/)
  end
end
