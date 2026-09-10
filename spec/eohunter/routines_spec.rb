# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'the routine words in routines.rb' do
  RoutineSpell = Struct.new(:num, :known, :affordable, :active, :name, keyword_init: true) do
    def known? = known
    def affordable? = affordable
    def active? = active
    def timeleft = 0.0
    def last_cast = Time.at(0)
    def mana_cost = 5
    def cast(*_a) = log(:cast)
    def force_cast(*_a) = log(:force_cast)
    def force_incant(*_a) = log(:force_incant)
    def force_evoke(*_a) = log(:force_evoke)
    def force_channel(*_a) = log(:force_channel)
    def calls = (@calls ||= [])
    def log(kind) = (calls << kind; 'Cast Roundtime 3 Seconds.')
  end unless defined?(RoutineSpell)

  def npc(id, name = 'kobold', type: 'aggressive npc', status: '')
    OpenStruct.new(id: id.to_s, name: name, noun: name.split.last, status: status, type: type)
  end

  let(:me) do
    OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false, standing?: true,
                   current_target_id: '1', hidden?: false, mana: 100, stamina: 100, max_stamina: 100, spirit: 10, health_pct: 100,
                   encumbrance_pct: 0, kneeling?: false, profession: 'Sorcerer', moc_ranks: 0, diseased?: false, poisoned?: false,
                   shadow_essence: 0, rt: 0.0, prepared_spell: 'None', stance_text: 'offensive', inventory_nouns: [], able_to_use_ranged?: true)
  end
  let(:room) { OpenStruct.new(id: 1, targets: [npc(1)], players: [], loot: [], exits: ['north'], title: '[x]') }
  let(:spells) { {} }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(id: '9', name: 'a katana', noun: 'katana'), left: OpenStruct.new(id: nil, name: 'Empty', noun: '')) }
  let(:world) { OpenStruct.new(me: me, room: room, spell: spells, hands: hands, claim_mine?: true, foreign_disks: [], group_nouns: []) }
  let(:policy) { EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack'] }) }
  let(:tp) { EO::Engine::Targets::Policy.new }
  let(:engage) { described_engage }
  let(:sent) { [] }

  def described_engage
    e = EO::Engine::Behaviors::Engage.new(policy: policy, targets_policy: tp, stance: ->(_s) { true })
    e.retarget(room.targets.first)
    e
  end

  def spell(num, **o) = spells[num] = RoutineSpell.new(num: num, known: true, affordable: true, active: false, name: "Spell #{num}", **o)

  # every Action sends through the seams; record and answer with +reply+
  def wire(klass, reply = 'ok', &block)
    allow_any_instance_of(klass).to receive(:send_through_ladder) { |_a, cmd| sent << cmd; block ? block.call(cmd) : reply }
    allow_any_instance_of(klass).to receive(:send_and_match) do |_a, cmd, _rx, **|
      sent << cmd
      line = block ? block.call(cmd) : reply
      EO::Engine::Actions::Result.new(status: :success, line: line)
    end
    allow_any_instance_of(klass).to receive(:sleep)
    allow_any_instance_of(klass).to receive(:next_line).and_return(nil)
    allow_any_instance_of(klass).to receive(:live_target_ids).and_return(nil)
  end

  before do
    %i[spell_active? cooldown_active? debuff_active? spell_effect_active? effect_active? buff_matching?].each { |m| me.define_singleton_method(m) { |_n| false } }
    me.define_singleton_method(:buff_time_left) { |_n| 0.0 }
    me.define_singleton_method(:spell_effect_time_left) { |_n| 0.0 }
    me.define_singleton_method(:cooldown_time_left) { |_n| 0.0 }
    me.define_singleton_method(:inventory_named) { |_n| nil }
  end

  after { EO::Engine::Events.reset! }

  def run(text)
    line = EO::Engine::Engage::Routine.parse([text]).first
    engage.dispatch(world, text, line)
  end

  it 'sacrifices only an enticingly frail target with spirit to spare' do
    wire(EO::Engine::Actions::Sacrifice)
    allow_any_instance_of(EO::Engine::Actions::Sacrifice).to receive(:appraise).and_return(['The kobold is small in size and appears enticingly frail.'])
    expect(run('sacrifice')).to be_success
    expect(sent).to eq(['sacrifice #1'])
    me.spirit = 1
    expect(run('sacrifice').reason).to eq(:low_spirit)
  end

  it 'casts phase, caststop and the curse through their spells' do
    spell(704); spell(720); spell(715)
    wire(EO::Engine::Actions::Curse)
    wire(EO::Engine::Actions::CastStop)
    expect(run('phase').reason).to eq(:phased)
    expect(spells[704].calls).to eq([:force_cast])
    expect(run('caststop 720 evoke').reason).to eq(:cast_stopped)
    expect(sent).to eq(['stop 720'])
    sent.clear
    prepped = false
    allow(me).to receive(:prepared_spell) { prepped ? 'Curse' : 'None' }
    allow_any_instance_of(EO::Engine::Actions::Curse).to receive(:send_and_match) { |_a, cmd, _rx, **| sent << cmd; prepped = true if cmd == 'prep 715'; EO::Engine::Actions::Result.new(status: :success, line: 'ok') }
    expect(run('curse hex')).to be_success
    expect(sent).to eq(['prep 715', 'curse #1 hex'])
  end

  it 'tethers, and chases the transferred chains when asked' do
    spell(706)
    lines = ['As the signs of life fade from a kobold, the tenebrous chains binding a kobold begin to vibrate and emit a sinister thrum that emanates through the surrounding area.']
    allow_any_instance_of(EO::Engine::Actions::Tether).to receive(:next_line) { lines.shift }
    allow_any_instance_of(EO::Engine::Actions::Tether).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::Tether).to receive(:live_target_ids).and_return(nil)
    tick = 0
    allow_any_instance_of(EO::Engine::Actions::Tether).to receive(:clock_now) { tick += 1; Time.at(tick) }
    room.targets << npc(2, 'orc')
    me.current_target_id = '2'
    result = run('tether recast')
    expect(spells[706].calls.size).to eq(2) # the recast on the orc
    expect(result).to be_success
  end

  it 'picks a resonance bolt that is not the last one, and rapid fire by its gates' do
    spell(908); spell(910); spell(515)
    allow(EO::Engine::Actions::Cast).to receive(:new) { |_w, spell:, **| instance_double(EO::Engine::Actions::Cast, call: EO::Engine::Actions::Result.new(status: :success, reason: spell)) }
    first = run('resonance 908 910').reason
    expect([908, 910]).to include(first)
    expect(run('resonance 908 910').reason).to eq(([908, 910] - [first]).first)
    expect(run('rapid').reason).to eq(515)
    me.define_singleton_method(:cooldown_active?) { |n| n == 'Rapid Fire Recovery' }
    expect(run('rapid').reason).to eq(:cooldown)
    expect(run('rapid ignore').reason).to eq(515)
  end

  it 'runs the celerity prefix before the command' do
    spell(506)
    allow(EO::Engine::Actions::Cast).to receive(:new) { |_w, spell:, **| instance_double(EO::Engine::Actions::Cast, call: EO::Engine::Actions::Result.new(status: :success, reason: spell)) }
    wire(EO::Engine::Actions::Attack, 'You swing a katana at a kobold!')
    allow(EO::Engine::Actions::Attack).to receive(:initiation_regex).and_return(/You swing/)
    result = run('celerity attack')
    expect(result).to be_success
    expect(sent).to eq(['attack'])
  end

  it 'forces a command until the roll reaches the goal' do
    wire(EO::Engine::Actions::Attack, 'You swing a katana at a kobold!')
    allow(EO::Engine::Actions::Attack).to receive(:initiation_regex).and_return(/You swing/)
    allow(EO::Engine::Engage::Routines).to receive(:sleep)
    swings = 0
    original = EO::Engine::Actions::Attack.instance_method(:call)
    allow_any_instance_of(EO::Engine::Actions::Attack).to receive(:call) do |a|
      swings += 1
      EO::Engine::Events.emit(:force_roll, roll: swings >= 3 ? 150 : 90)
      original.bind(a).call
    end
    expect(run('force attack until 120').reason).to eq(:goal_met)
    expect(swings).to eq(3)
  end

  it 'runs a command at each target and comes back to ours' do
    room.targets << npc(2, 'orc')
    targeted = []
    allow(EO::Engine::Actions::Target).to receive(:new) { |_w, target:| targeted << target.id; instance_double(EO::Engine::Actions::Target, call: EO::Engine::Actions::Result.new(status: :success)) }
    wire(EO::Engine::Actions::Attack, 'You swing a katana at a kobold!')
    allow(EO::Engine::Actions::Attack).to receive(:initiation_regex).and_return(/You swing/)
    run('eachtarget attack')
    expect(targeted).to eq(['2']) # ours is already the game's target
    expect(engage.target.id).to eq('1')
  end

  it "does not aim or fire when Lich's Injured says the arms cannot" do
    policy.archery_aim = ['head']
    me[:able_to_use_ranged?] = false
    wire(EO::Engine::Actions::Ranged)
    expect(run('fire').reason).to eq(:too_injured)
    expect(sent).to be_empty
  end

  it 'fires with the aim list, skipping a part an arrow is stuck in' do
    policy.archery_aim = ['head', 'chest']
    wire(EO::Engine::Actions::Ranged, 'Roundtime: 3 sec.')
    allow_any_instance_of(EO::Engine::Actions::Ranged).to receive(:vitals).and_return(nil)
    expect(run('fire')).to be_success
    expect(sent).to eq(['aim head', 'fire #1'])
    sent.clear
    EO::Engine::Events.emit(:arrow_stuck, id: '1', where: 'head')
    EO::Engine::Events.emit(:aiming, where: 'head')
    run('fire')
    expect(sent).to eq(['aim chest', 'fire #1'])
  end

  it "stows a weapon the game will not fire into the ammo container through Lich's Stash" do
    policy.archery_aim = ['head']
    policy.ammo_container = 'quiver'
    quiver = OpenStruct.new(id: '77', name: 'a leather quiver', noun: 'quiver')
    me.define_singleton_method(:inventory_named) { |_n| quiver }
    stashed = []
    wire(EO::Engine::Actions::Ranged) { |cmd| cmd =~ /^fire/ ? 'You cannot fire that.' : 'The quiver is closed.' }
    allow_any_instance_of(EO::Engine::Actions::Ranged).to receive(:vitals).and_return(nil)
    allow_any_instance_of(EO::Engine::Actions::Ranged).to receive(:stash_into) { |_a, container, weapon| stashed << [container.id, weapon.id]; true }
    expect(run('fire').reason).to eq(:cannot_fire)
    expect(sent).to eq(['aim head', 'fire #1', 'stow #9'])
    expect(stashed).to eq([['77', '9']])
  end

  it 'dislodges the listed location the arrow stuck in' do
    allow_any_instance_of(EO::Engine::Actions::Dislodge).to receive(:cman_available?).and_return(true)
    wire(EO::Engine::Actions::Dislodge, 'You manage to dislodge the arrow.')
    expect(run('dislodge head chest').reason).to eq(:wrong_target)
    engage.state.dislodge_target = '1'
    expect(run('dislodge head chest').reason).to eq(:nothing_lodged)
    EO::Engine::Events.emit(:arrow_stuck, id: '1', where: 'chest')
    expect(run('dislodge head chest').reason).to eq(:dislodged)
    expect(sent).to eq(['cman dislodge #1 chest'])
  end

  it 'waves the next fresh wand and stores a dead one' do
    policy.fresh_wand_container = 'satchel'
    policy.dead_wand_container = 'sack'
    policy.wand = ['iron wand', 'gold wand']
    hands.right = OpenStruct.new(id: '5', name: 'an iron wand', noun: 'wand')
    allow_any_instance_of(EO::Engine::Actions::Wand).to receive(:send_through_ladder) { |_a, cmd| sent << cmd; 'ok' }
    allow_any_instance_of(EO::Engine::Actions::Wand).to receive(:send_and_match) { |_a, cmd, _rx, **| sent << cmd; cmd =~ /^wave/ ? EO::Engine::Actions::Result.new(status: :timeout, reason: :no_confirmation) : EO::Engine::Actions::Result.new(status: :success, line: 'ok') }
    allow_any_instance_of(EO::Engine::Actions::Wand).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::Wand).to receive(:live_target_ids).and_return(nil)
    expect(run('wand').reason).to eq(:dead_wand)
    expect(sent).to eq(['wave my iron wand at #1', 'put my iron wand in my sack'])
  end

  it 'hurls at the next ambush part and recovers the weapon' do
    policy.ambush = ['head', 'chest']
    wire(EO::Engine::Actions::Dhurl) { |cmd| cmd =~ /^hurl/ ? 'You throw a katana at a kobold!' : 'You spy a katana and recover it!' }
    wire(EO::Engine::Actions::RecoverHurl) { |_cmd| 'You spy a katana and recover it!' }
    expect(run('dhurl').reason).to eq(:recovered)
    expect(sent).to eq(['hurl #1 head', 'recover hurl'])
    expect(EO::Engine::Actions::RecoverHurl.new(world, state: engage.state, room: 999).call.reason).to eq(:not_in_throw_room)
  end

  it 'reads the unarmed tier and follow-up from the swing, and mstrikes first' do
    policy.tier3 = 'punch'
    policy.uac_mstrike = true
    lines = ['You have excellent positioning against a kobold.', 'Strike leaves foe vulnerable to a followup jab attack!', 'Roundtime: 3 sec.']
    allow_any_instance_of(EO::Engine::Actions::Unarmed).to receive(:send_through_ladder) { |_a, cmd| sent << cmd; 'You punch at a kobold!' }
    allow_any_instance_of(EO::Engine::Actions::Unarmed).to receive(:next_line) { lines.shift }
    allow_any_instance_of(EO::Engine::Actions::Unarmed).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::Unarmed).to receive(:live_target_ids).and_return(nil)
    expect(run('unarmed jab').reason).to eq(:swung)
    expect(sent).to eq(['jab #1'])
    expect(engage.state.unarmed_tier).to eq(3)
    expect(engage.state.unarmed_followup_attack).to eq('jab')
    sent.clear
    lines.replace(['Roundtime: 3 sec.'])
    run('unarmed jab')
    expect(sent).to eq(['jab #1']) # the follow-up word
  end

  it 'performs a weapon reaction the game offered before the next line' do
    engage
    EO::Engine::Events.emit(:weapon_reaction, reaction: 'riposte #1')
    wire(EO::Engine::Actions::Reaction)
    wire(EO::Engine::Actions::Attack, 'You swing a katana at a kobold!')
    allow(EO::Engine::Actions::Attack).to receive(:initiation_regex).and_return(/You swing/)
    line = EO::Engine::Engage::Routine.parse(['attack']).first
    engage.send(:run_line, world, line)
    expect(sent).to eq(['weapon riposte #1', 'attack'])
    expect(engage.state.reaction).to be_nil
  end
end
