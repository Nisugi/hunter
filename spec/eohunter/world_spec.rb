# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::World do
  # Test double mirroring Lich's shapes (GameObj: "Empty"-named hand objects,
  # frozen 'gone' statuses; XMLData: indicator hash of 'y'/'n').
  let(:npc) { Struct.new(:id, :noun, :name, :status) }
  let(:hand) { Struct.new(:id, :noun, :name) }

  let(:xmldata) do
    OpenStruct.new(
      health: 120, max_health: 150, mana: 40, max_mana: 100,
      stamina: 80, max_stamina: 100, spirit: 10, max_spirit: 10,
      roundtime_end: 0, cast_roundtime_end: 0, server_time_offset: 0,
      indicator: { 'IconSTANDING' => 'y', 'IconSTUNNED' => 'n', 'IconDEAD' => 'n',
                   'IconWEBBED' => 'n', 'IconPRONE' => 'n', 'IconHIDDEN' => 'n' },
      stance_text: 'offensive', stance_value: 0,
      room_id: 8003, room_title: '[Kobold Village]', room_count: 7,
      room_exits: %w[north east], prepared_spell: 'None'
    )
  end

  let(:kobold) { npc.new('1234', 'kobold', 'a kobold', nil) }
  let(:dead_gnoll) { npc.new('5678', 'gnoll', 'a gnoll worker', 'dead') }
  let(:gone_rat) { npc.new('9999', 'rat', 'a giant rat', 'gone') }

  let(:gameobj) do
    double('GameObj',
           npcs: [kobold, dead_gnoll, gone_rat],
           pcs: nil,
           loot: nil,
           right_hand: hand.new('7777', 'sword', 'a steel short sword'),
           left_hand: hand.new(nil, nil, 'Empty'))
  end

  let(:spell_mod) { double('Spell', active: [OpenStruct.new(num: 401), OpenStruct.new(num: 414)]) }
  let(:map_mod)   { double('Map', current: OpenStruct.new(id: 288)) }
  let(:stats_mod) { double('Stats', level: 5, profession: 'Warrior') }

  subject(:world) do
    w = described_class.new
    allow(w).to receive_messages(xmldata: xmldata, gameobj: gameobj, spell: spell_mod,
                                 map: map_mod, stats: stats_mod)
    w
  end

  describe 'Me' do
    it 'reads vitals and percentages' do
      expect(world.me.health).to eq(120)
      expect(world.me.health_pct).to eq(80)
      expect(world.me.mana_pct).to eq(40)
    end

    it 'guards percentage against zero max' do
      xmldata.max_mana = 0
      expect(world.me.mana_pct).to eq(0)
    end

    it 'computes remaining RT with server offset, clamped at zero' do
      now = Time.now
      allow(world).to receive(:clock).and_return(double(now: now))
      xmldata.roundtime_end = now.to_f + 3
      xmldata.server_time_offset = 0
      expect(world.me.rt).to be_within(0.01).of(3.0)
      expect(world.me.in_rt?).to be(true)

      xmldata.roundtime_end = now.to_f - 5
      expect(world.me.rt).to eq(0.0)
      expect(world.me.in_rt?).to be(false)
    end

    it 'reads indicators' do
      expect(world.me.standing?).to be(true)
      expect(world.me.stunned?).to be(false)
      xmldata.indicator['IconSTUNNED'] = 'y'
      expect(world.me.stunned?).to be(true)
    end

    it "reads the mind state from Lich's checksaturated and checkfried" do
      allow(world).to receive_messages(saturated?: true, fried?: true)
      expect(world.me.saturated?).to be(true)
      expect(world.me.fried?).to be(true)
    end

    it 'lists active spell numbers' do
      expect(world.me.active_spell_numbers).to eq([401, 414])
    end
  end

  describe 'RoomView' do
    it "names bigshot's four hazard families from the object list, by toggle" do
      cloud = npc.new('1', 'cloud', 'a noxious gas cloud', nil)
      circle = npc.new('2', 'circle', 'intense shimmering circle', nil)
      vine = npc.new('3', 'vine', 'a thorny vine', nil)
      web = npc.new('4', 'web', 'a sticky web', nil)
      void = npc.new('5', 'void', 'a black void', nil)
      fog = npc.new('6', 'fog', 'a thick fog', nil)
      allow(gameobj).to receive(:loot).and_return([cloud, circle, vine, web, void, fog])
      expect(world.room.hazards.map(&:id)).to eq(%w[1 2 3 4 5])
      expect(world.room.hazards(kinds: [:vine]).map(&:id)).to eq(['3'])
      expect(world.room.hazard_kind).to eq(:cloud)
      expect(world.room.hazard_kind(kinds: %i[web void])).to eq(:web)
      expect(world.room.hazardous?(kinds: [])).to be false
    end

    it 'filters dead and gone creatures out of live_creatures' do
      expect(world.room.creatures.size).to eq(3)
      expect(world.room.live_creatures).to eq([kobold])
    end

    it 'handles nil GameObj registries as empty' do
      expect(world.room.players).to eq([])
      expect(world.room.loot).to eq([])
      expect(world.room.empty_of_players?).to be(true)
    end

    it 'exposes both room identities (Lich id and game UID)' do
      expect(world.room.uid).to eq(8003)
      expect(world.room.id).to eq(288)
    end
  end

  describe 'Hands' do
    it "treats Lich's Empty-named nil-id object as an empty hand" do
      expect(world.hands.right_empty?).to be(false)
      expect(world.hands.left_empty?).to be(true)
      expect(world.hands.empty?).to be(false)
    end

    it 'matches held items by noun pattern' do
      expect(world.hands.holding?(/sword/)).to be(true)
      expect(world.hands.holding?(/runestaff/)).to be(false)
    end
  end
end
