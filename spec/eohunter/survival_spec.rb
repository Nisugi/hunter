# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Survival::Predicates do
  def pc(noun, status)
    OpenStruct.new(id: noun, name: noun, noun: noun, status: status)
  end

  let(:me) { OpenStruct.new(dead?: false, standing?: true, muckled?: false, webbed?: false, sleeping?: false, stunned?: false) }
  let(:room) { OpenStruct.new(title: '[Kobold Village]', players: [], targets: []) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: ['Bob']) }
  let(:policy) { EO::Engine::Survival::Policy.new }

  def reason(**opts) = described_class.reason(world, policy, **opts)

  it 'is nil when all is well' do
    expect(reason).to be_nil
  end

  it 'ranks dead, trapped, deader, prone, pull' do
    room.players = [pc('Bob', 'lying down'), pc('Ann', 'dead')]
    expect(reason).to eq(:pull)
    me[:standing?] = false
    expect(reason).to eq(:prone)
    policy.deader = true
    expect(reason).to eq(:deader)
    room.title = '[The Belly of the Beast]'
    expect(reason).to eq(:trapped)
    me[:dead?] = true
    expect(reason).to eq(:dead)
  end

  it 'does not stand while resting or muckled' do
    me[:standing?] = false
    expect(reason(resting: true)).to be_nil
    me[:muckled?] = true
    expect(reason).to be_nil
  end

  it 'pulls anyone down while a creature is up with pull on, else only the group' do
    room.players = [pc('Ann', 'sitting'), pc('Bob', 'lying down')]
    expect(described_class.to_pull(world, policy).map(&:noun)).to eq(['Bob'])
    room.targets = [OpenStruct.new(type: 'aggressive npc')]
    expect(described_class.to_pull(world, policy).map(&:noun)).to eq(['Ann', 'Bob'])
    policy.pull = false
    expect(described_class.to_pull(world, policy).map(&:noun)).to eq(['Bob'])
  end

  it 'sees a stunned group member' do
    expect(described_class.group_member_stunned?(world)).to be false
    room.players = [pc('Ann', 'stunned'), pc('Bob', 'webbed')]
    expect(described_class.group_member_stunned?(world)).to be true
    room.players = [pc('Ann', 'stunned')]
    expect(described_class.group_member_stunned?(world)).to be false
    me[:stunned?] = true
    expect(described_class.group_member_stunned?(world)).to be true
  end
end

RSpec.describe EO::Engine::Actions::Stand do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, standing?: false, stance_text: 'offensive') }
  let(:room) { OpenStruct.new(title: '[Kobold Village]') }
  let(:world) { OpenStruct.new(me: me, room: room) }
  let(:stances) { [] }
  let(:sent) { [] }

  def stand(**opts)
    action = described_class.new(world, stance: ->(s) { stances << s; true }, timeout: 0.05, **opts)
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; me[:standing?] = sent.size >= 2; 'You stand back up.' }
    allow(action).to receive(:sleep)
    action
  end

  it 'drops to the stand stance, stands, and restores the stance' do
    expect(stand.call).to be_success
    expect(sent).to eq(['stand', 'stand'])
    expect(stances).to eq(['defensive', 'offensive'])
  end

  it 'gives up after the attempts and never stands in the ooze' do
    expect(stand(attempts: 1).call.reason).to eq(:still_down)
    room.title = '[Ooze, Innards]'
    expect(stand.call.reason).to eq(:in_ooze)
  end
end

RSpec.describe EO::Engine::Behaviors::Survival do
  let(:me) { OpenStruct.new(dead?: false, standing?: true, muckled?: false, webbed?: false, sleeping?: false, stunned?: false, in_rt?: false, in_cast_rt?: false) }
  let(:room) { OpenStruct.new(id: 1, title: '[Kobold Village]', players: [], targets: []) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: []) }
  let(:policy) { EO::Engine::Survival::Policy.new(deader: true) }
  let(:survival) { described_class.new(policy: policy) }

  after { EO::Engine::Events.reset! }

  it 'does not want control when all is well' do
    expect(survival.wants_control?(world)).to be false
  end

  it 'reports a death once and fails :dead with on_death :stop' do
    deaths = []
    EO::Engine::Events.on(:died) { |e| deaths << e.data[:on_death] }
    me[:dead?] = true
    expect(survival.wants_control?(world)).to be true
    expect(survival.tick(world).reason).to eq(:dead)
    survival.tick(world)
    expect(deaths).to eq([:stop])
  end

  it 'departs when asked' do
    policy.on_death = :depart
    me[:dead?] = true
    depart = instance_double(EO::Engine::Actions::Depart, call: EO::Engine::Actions::Result.new(status: :success, reason: :departed))
    expect(EO::Engine::Actions::Depart).to receive(:new).with(world).and_return(depart)
    survival.wants_control?(world)
    expect(survival.tick(world).reason).to eq(:departed)
  end

  it 'stops over a dead player and says so once per room' do
    seen = []
    EO::Engine::Events.on(:deader) { |e| seen << e.data[:players] }
    room.players = [OpenStruct.new(noun: 'Ann', status: 'dead')]
    expect(survival.wants_control?(world)).to be true
    expect(survival.tick(world).reason).to eq(:deader)
    survival.tick(world)
    expect(seen).to eq([['Ann']])
  end

  it 'escapes, stands and pulls through the actions' do
    room.title = '[Temporal Rift]'
    escape = instance_double(EO::Engine::Actions::Escape, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Escape).to receive(:new).with(world).and_return(escape)
    survival.wants_control?(world)
    expect(survival.tick(world)).to be_success
    room.title = '[Kobold Village]'
    me[:standing?] = false
    stand = instance_double(EO::Engine::Actions::Stand, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Stand).to receive(:new).and_return(stand)
    survival.wants_control?(world)
    survival.tick(world)
    me[:standing?] = true
    room.players = [OpenStruct.new(noun: 'Ann', status: 'sitting')]
    room.targets = [OpenStruct.new(type: 'aggressive npc')]
    pull = instance_double(EO::Engine::Actions::Pull, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Pull).to receive(:new).with(world, player: room.players.first).and_return(pull)
    survival.wants_control?(world)
    survival.tick(world)
  end

  it 'tracks rooted from the watch and clears it on a new room' do
    survival
    EO::Engine::Events.emit(:rooted)
    expect(survival.rooted?).to be true
    EO::Engine::Events.emit(:entered_room, room: 2)
    expect(survival.rooted?).to be false
  end
end
