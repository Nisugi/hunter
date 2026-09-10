# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'EOHunter controller refuge observation' do
  # Load only the real script adapter; loading the full .lic would launch a hunt.
  let(:adapter) do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    method = source[/  def self\.controller_snapshot\(.*?(?=  def self\.run_controlled)/m]
    Module.new.tap { |mod| mod.module_eval(method) }
  end
  let(:owner) { Object.new }
  let(:gameobj) { OpenStruct.new(right_hand: nil, left_hand: nil, targets: [], npcs: [], hidden_targets: []) }

  before do
    stub_const('XMLData', OpenStruct.new(room_count: 1, game: 'TEST', indicator: { 'IconSTANDING' => 'y' }))
    stub_const('Room', OpenStruct.new(current: OpenStruct.new(id: 1000)))
    stub_const('GameObj', gameobj)
    stub_const('Char', OpenStruct.new(name: 'Testmage', health: 100, spirit: 10))
    stub_const('Game', OpenStruct.new(closed?: false))
    stub_const('Lich::Gemstone::Overwatch', OpenStruct.new(hiders?: false))
    allow(Script).to receive(:list).and_return([owner])
    adapter.define_singleton_method(:dead?) { false }
  end

  def snapshot = adapter.controller_snapshot(owner, 'test-session')

  it 'accepts a stable empty room but rejects creatures known only through the combat dialog' do
    expect(snapshot[:destination_safe]).to be true
    gameobj.hidden_targets = ['99']
    expect(snapshot[:destination_safe]).to be false
  end

  it 'rejects a creature Overwatch observed hiding even without a visible target' do
    Lich::Gemstone::Overwatch[:hiders?] = true
    expect(snapshot[:destination_safe]).to be false
  end

  it 'rejects a room transition during observation' do
    allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1000), OpenStruct.new(id: 1001))
    expect(snapshot[:stable]).to be false
  end
end
