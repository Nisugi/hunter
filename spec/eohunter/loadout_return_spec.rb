# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe 'Managed hurled equipment' do
  let(:world) { FakeWorld.new }
  let(:state) { EO::Engine::Engage::State.new }
  let(:target) { OpenStruct.new(id: '1', name: 'kobold', status: '') }
  let(:engage) do
    EO::Engine::Behaviors::Engage.new(policy: EO::Engine::Engage::Policy.new,
                                      targets_policy: EO::Engine::Targets::Policy.new, state: state)
  end
  let(:failures) { [] }
  let(:ok) { EO::Engine::Actions::Result.new(status: :success) }
  let(:now) { [Time.at(100)] }

  before do
    world.right_id = 'weapon'
    engage.retarget(target)
    engage.equipment_failed = ->(_world, result) { failures << result.reason }
    allow_any_instance_of(EO::Engine::Actions::RecoverHurl).to receive(:clock_now) { now.first }
    allow(EO::Engine::Events).to receive(:await) { |*, timeout:| now[0] += timeout }
  end

  after { EO::Engine::Events.reset! }

  def hurl
    line = EO::Engine::Engage::Routine.parse(['hurl target']).first
    engage.dispatch(world, 'hurl #1', line)
  end

  def throw(&block)
    action = instance_double(EO::Engine::Actions::Attack)
    allow(EO::Engine::Actions::Attack).to receive(:new).and_return(action)
    allow(action).to receive(:call) { world.right_id = nil; block&.call; ok }
  end

  it 'finishes the killing throw cleanup before handing back control' do
    throw { target.status = 'dead' }
    allow(EO::Engine::Events).to receive(:await) do |*, timeout:|
      now[0] += timeout
      world.right_id = 'weapon'
      EO::Engine::Events.emit(:bond_return)
    end
    expect(EO::Engine::Actions::EstablishLoadout).not_to receive(:new)

    expect(hurl).to be_success
    expect(world.right_id).to eq('weapon')
    expect(failures).to be_empty
  end

  it 'does not treat a bond event or a replacement ID as the expected weapon' do
    throw { world.right_id = 'replacement'; EO::Engine::Events.emit(:bond_return) }

    expect(hurl.reason).to eq(:equipment_return_timeout)
    expect(failures).to eq([:equipment_return_timeout])
    expect(now.first).to be <= Time.at(110.1)
  end

  it 'delegates ordinary recovery to RecoverHurl after the flight window' do
    throw
    allow_any_instance_of(EO::Engine::Actions::RecoverHurl).to receive(:send_and_match) do |_action, command, _answers, **|
      expect(command).to eq('recover hurl')
      world.right_id = 'weapon'
      EO::Engine::Actions::Result.new(status: :success, line: 'You spy a spear and recover it')
    end

    expect(hurl).to be_success
    expect(failures).to be_empty
  end

  it 'reports interrupted cleanup immediately without trying to recover or move' do
    throw
    engage.equipment_interrupt = ->(_world) { true }
    expect_any_instance_of(EO::Engine::Actions::RecoverHurl).not_to receive(:send_and_match)

    expect(hurl.reason).to eq(:interrupted)
    expect(failures).to eq([:interrupted])
  end

  it 'reports an ambiguous throw when both original hand items disappear' do
    world.left_id = 'other'
    throw { world.left_id = nil }

    expect(hurl.reason).to eq(:throw_hand_ambiguous)
    expect(failures).to eq([:throw_hand_ambiguous])
  end

  it 'identifies the departed weapon while a shield stays in the other hand' do
    world.left_id = 'shield'
    throw
    allow(EO::Engine::Events).to receive(:await) do |*, timeout:|
      now[0] += timeout
      world.right_id = 'weapon'
    end

    expect(hurl).to be_success
    expect(world.left_id).to eq('shield')
    expect(failures).to be_empty
  end

  it 'verifies an offhand departure from IDs without treating body-part left as a hand selector' do
    world.left_id = 'other'
    action = instance_double(EO::Engine::Actions::Attack)
    allow(EO::Engine::Actions::Attack).to receive(:new).and_return(action)
    allow(action).to receive(:call) { world.left_id = nil; ok }
    allow(EO::Engine::Events).to receive(:await) do |*, timeout:|
      now[0] += timeout
      world.left_id = 'other'
    end
    line = EO::Engine::Engage::Routine.parse(['hurl target left leg']).first

    expect(engage.dispatch(world, 'hurl #1 left leg', line)).to be_success
    expect(world.right_id).to eq('weapon')
    expect(failures).to be_empty
  end

  it 'uses the same bounded managed recovery for dhurl without its legacy sleep' do
    allow_any_instance_of(EO::Engine::Actions::Dhurl).to receive(:send_and_match) do |_action, _command, _answers, **|
      world.right_id = nil
      target.status = 'dead'
      EO::Engine::Actions::Result.new(status: :success, line: 'You throw a spear at a kobold!')
    end
    expect_any_instance_of(EO::Engine::Actions::Dhurl).not_to receive(:sleep)
    allow(EO::Engine::Events).to receive(:await) do |*, timeout:|
      now[0] += timeout
      world.right_id = 'weapon'
      EO::Engine::Events.emit(:bond_return)
    end
    line = EO::Engine::Engage::Routine.parse(['dhurl']).first

    expect(engage.dispatch(world, 'dhurl', line)).to be_success
    expect(failures).to be_empty
  end

  it 'keeps failed aimed parts retryable when dhurl never throws' do
    allow_any_instance_of(EO::Engine::Actions::Dhurl).to receive(:send_and_match)
      .and_return(EO::Engine::Actions::Result.new(status: :success, line: 'You cannot aim that high!'))
    expect(EO::Engine::Actions::RecoverHurl).not_to receive(:new)
    line = EO::Engine::Engage::Routine.parse(['dhurl']).first

    expect(engage.dispatch(world, 'dhurl', line).reason).to eq(:part_refused)
    expect(failures).to be_empty
  end

  it 'does not chase the weapon if the room changes during the throw' do
    throw { world.id = 2 }
    expect_any_instance_of(EO::Engine::Actions::RecoverHurl).not_to receive(:send_and_match)

    expect(hurl.reason).to eq(:not_in_throw_room)
    expect(failures).to eq([:not_in_throw_room])
  end

  it 'leaves ordinary profiles on the original attack path' do
    engage.equipment_failed = nil
    throw
    expect(EO::Engine::Actions::RecoverHurl).not_to receive(:new)

    expect(hurl).to be_success
    expect(failures).to be_empty
  end

  it 'latches an uncertain attack timeout even before hand XML catches up' do
    action = instance_double(EO::Engine::Actions::Attack,
                             call: EO::Engine::Actions::Result.new(status: :timeout, reason: :timeout))
    allow(EO::Engine::Actions::Attack).to receive(:new).and_return(action)

    expect(hurl.reason).to eq(:timeout)
    expect(failures).to eq([:timeout])
  end
end
