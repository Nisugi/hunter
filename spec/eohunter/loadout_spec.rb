# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Loadout do
  let(:hand_class) { Struct.new(:id, :noun, :name, keyword_init: true) }

  def item(id, name, noun: name.split.last)
    hand_class.new(id: id.to_s, noun: noun, name: name)
  end

  let(:staff) { item(1, 'a vermilion runestaff', noun: 'runestaff') }
  let(:shield) { item(2, 'a black vultite shield', noun: 'shield') }
  let(:empty) { hand_class.new(id: nil, noun: nil, name: 'Empty') }
  let(:hands) { OpenStruct.new(right: staff, left: empty) }
  let(:adapter) do
    instance_double(
      EO::Engine::Loadout::Core,
      ready_item: nil,
      name_match?: false,
      reconcile: nil
    )
  end

  describe EO::Engine::Loadout::Reference do
    it 'parses control words, ready slots and literal names' do
      expect(described_class.parse(nil)).to have_attributes(kind: :keep, value: nil)
      expect(described_class.parse(' KEEP ')).to have_attributes(kind: :keep, value: nil)
      expect(described_class.parse('Empty')).to have_attributes(kind: :empty, value: nil)
      expect(described_class.parse('READY:Secondary Weapon')).to have_attributes(kind: :ready, value: :secondary_weapon)
      expect(described_class.parse('my midnight-black maul')).to have_attributes(kind: :name, value: 'my midnight-black maul')
    end

    it 'translates directly to the Lich Stash hands contract' do
      expect(described_class.parse('keep').stash_value).to eq(:keep)
      expect(described_class.parse('empty').stash_value).to be_nil
      expect(described_class.parse('ready:shield').stash_value).to eq(:shield)
      expect(described_class.parse('black maul').stash_value).to eq('black maul')
    end

    it 'matches without asking the adapter to reconcile anything' do
      allow(adapter).to receive(:ready_item).with(:weapon).and_return(staff)
      allow(adapter).to receive(:name_match?).with(staff, 'vermilion staff').and_return(true)

      expect(described_class.parse('keep')).to be_satisfied_by(shield, adapter: adapter)
      expect(described_class.parse('empty')).to be_satisfied_by(empty, adapter: adapter)
      expect(described_class.parse('ready:weapon')).to be_satisfied_by(staff, adapter: adapter)
      expect(described_class.parse('vermilion staff')).to be_satisfied_by(staff, adapter: adapter)
      expect(adapter).not_to have_received(:reconcile)
    end
  end

  describe EO::Engine::Loadout::Policy do
    it 'defaults to keep/keep and only manages explicit requirements' do
      expect(described_class.new).not_to be_managed
      expect(described_class.new(right: 'ready:weapon')).to be_managed
    end

    it 'requires both managed hands to match the same snapshot' do
      policy = described_class.new(right: 'ready:weapon', left: 'ready:shield')
      allow(adapter).to receive(:ready_item).with(:weapon).and_return(staff)
      allow(adapter).to receive(:ready_item).with(:shield).and_return(shield)

      expect(policy).not_to be_satisfied(hands, adapter: adapter)
      hands.left = shield
      expect(policy).to be_satisfied(hands, adapter: adapter)
    end
  end

  describe EO::Engine::Actions::EstablishLoadout do
    let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false) }
    let(:world) { OpenStruct.new(me: me, hands: hands) }
    let(:policy) { EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty') }

    it 'delegates the complete transaction to Stash once and verifies it' do
      allow(adapter).to receive(:ready_item).with(:weapon).and_return(staff)

      result = described_class.new(world, policy: policy, adapter: adapter).call

      expect(adapter).to have_received(:reconcile).once.with(right: :weapon, left: nil)
      expect(result).to be_success
      expect(result.reason).to eq(:established)
      expect(result).not_to be_acted # Stash owns sends; the action must not invent them.
    end

    it 'sends one AIM for an aimed set, after the hands verify' do
      aimed = EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty', aim: 'right eye')
      allow(adapter).to receive(:ready_item).with(:weapon).and_return(staff)
      action = described_class.new(world, policy: aimed, adapter: adapter)
      sent = []
      allow(action).to receive(:game_send) { |cmd| sent << cmd; 'You are now aiming at the right eye.' }

      result = action.call

      expect(sent).to eq(['aim right eye'])
      expect(result).to be_success
    end

    it 'does not aim when the set names no part' do
      allow(adapter).to receive(:ready_item).with(:weapon).and_return(staff)
      action = described_class.new(world, policy: policy, adapter: adapter)
      allow(action).to receive(:game_send)

      expect(action.call).to be_success
      expect(action).not_to have_received(:game_send)
    end

    it 'keeps a verified loadout when the AIM itself is refused' do
      aimed = EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty', aim: 'head')
      allow(adapter).to receive(:ready_item).with(:weapon).and_return(staff)
      action = described_class.new(world, policy: aimed, adapter: adapter)
      allow(action).to receive(:game_send).and_return(:too_many_resends)

      result = action.call

      expect(result).to be_success
      expect(result.reason).to eq(:established)
    end

    it 'does not aim when the hands failed to verify' do
      aimed = EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty', aim: 'head')
      hands.right = empty
      action = described_class.new(world, policy: aimed, adapter: adapter)
      allow(action).to receive(:game_send)

      expect(action.call).to be_failed
      expect(action).not_to have_received(:game_send)
    end

    it 'fails when Stash returns but the observed hands are still wrong' do
      hands.right = empty
      result = described_class.new(world, policy: policy, adapter: adapter).call

      expect(result).to be_failed
      expect(result.reason).to eq(:verification_failed)
    end

    [
      ['could not find Item[:weapon]', :item_missing],
      ['a container holding the maul is locked or would not open', :item_inaccessible],
      ['the same item was asked for in both hands', :invalid_loadout],
      ['could not move maul to the right hand', :reconciliation_failed]
    ].each do |message, reason|
      it "classifies #{reason}" do
        allow(adapter).to receive(:reconcile).and_raise(RuntimeError, message)

        result = described_class.new(world, policy: policy, adapter: adapter).call

        expect(result).to be_failed
        expect(result.reason).to eq(reason)
        expect(result.line).to eq(message)
      end
    end
  end

  describe EO::Engine::Behaviors::Loadout do
    let(:world) { OpenStruct.new(room: OpenStruct.new(id: 99), hands: hands) }
    let(:owner) { instance_double('HandOwner', owns_hands?: false) }
    let(:policy) { EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty') }
    let(:behavior) { described_class.new(policy: policy, owner: owner, adapter: adapter) }

    after do
      EO::Engine::Events.reset!
      EO::Engine::Travel.reset!
    end

    it 'sits after Loot and before Maintain, Engage and Wander' do
      expect(behavior.priority).to eq(35)
    end

    it 'does nothing for an unmanaged or already satisfied profile' do
      unmanaged = described_class.new(policy: EO::Engine::Loadout::Policy.new, owner: owner, adapter: adapter)
      allow(adapter).to receive(:ready_item).with(:weapon).and_return(staff)

      expect(unmanaged.wants_control?(world)).to be false
      expect(behavior.wants_control?(world)).to be false
    end

    it 'yields throughout a live combat routine even when the hands differ' do
      allow(owner).to receive(:owns_hands?).with(world).and_return(true)
      hands.right = empty

      expect(behavior.wants_control?(world)).to be false
    end

    it 'yields to go2 until destination cleanup releases the trip' do
      trip = instance_double(EO::Engine::Travel::Trip, underway?: true)
      EO::Engine::Travel.claim(trip)
      expect(behavior.wants_control?(world)).to be false
      EO::Engine::Travel.release(trip)
      expect(behavior.wants_control?(world)).to be true
    end

    it 'does not undo resting equipment while a follower waits for orders' do
      resting = described_class.new(policy: policy, owner: owner, adapter: adapter, resting: -> { true })
      expect(resting.wants_control?(world)).to be false
    end

    it 'reports one specific stuck event per room and remains blocking' do
      hands.right = empty
      failed = EO::Engine::Actions::Result.new(status: :failed, reason: :item_missing, line: 'could not find Item[:weapon]')
      action = instance_double(EO::Engine::Actions::EstablishLoadout, call: failed)
      allow(EO::Engine::Actions::EstablishLoadout).to receive(:new).and_return(action)
      events = []
      EO::Engine::Events.on(:loadout_stuck) { |event| events << event.data }

      2.times do
        expect(behavior.wants_control?(world)).to be true
        behavior.tick(world)
      end

      expect(behavior).to be_stuck
      expect(action).to have_received(:call).once
      expect(events).to contain_exactly(include(room: 99, reason: :item_missing, message: 'could not find Item[:weapon]'))
    end
  end

  describe EO::Engine::Loadout::Core do
    it 'caches core-resolved names without using private Stash APIs in predicates' do
      stash = Module.new
      stash.define_singleton_method(:hands) { |**| { right: staff, left: nil } }
      stub_const('Lich::Stash', stash)
      allow(stash).to receive(:hands).with(right: 'vermilion staff', left: nil).and_return(right: staff, left: nil)
      core = described_class.new
      expect(core.name_match?(staff, 'vermilion staff')).to be false
      core.reconcile(right: 'vermilion staff', left: nil)
      expect(core.name_match?(staff, 'vermilion staff')).to be true
      expect(core.name_match?(shield, 'vermilion staff')).to be false
      expect(stash).to have_received(:hands).once
    end
  end
end
