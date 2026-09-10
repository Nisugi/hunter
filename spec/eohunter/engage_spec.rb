# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

EngageNpc = Struct.new(:id, :name, :noun, :status, :type, keyword_init: true) unless defined?(EngageNpc)

RSpec.describe EO::Engine::Engage::Routine do
  it 'splits the modifiers off the text and keeps the raw line' do
    lines = described_class.parse(['attack', '1030 (m20 once)', 'cman bullrush (!prone EB"Enh. Strength")'])
    expect(lines.map(&:text)).to eq(['attack', '1030', 'cman bullrush'])
    expect(lines[1].modifiers).to eq(['m20', 'once'])
    expect(lines[1].once?).to be true
    expect(lines[2].modifiers).to eq(['!prone', 'EB"Enh. Strength"'])
    expect(lines[1].raw).to eq('1030 (m20 once)')
  end
end

RSpec.describe EO::Engine::Engage::Conditions do
  let(:me) do
    OpenStruct.new(encumbrance_pct: 10, shadow_essence: 0, health_pct: 100, kneeling?: false, mana: 100, stamina: 100, spirit: 10,
                   hidden?: false, diseased?: false, poisoned?: false)
  end
  let(:room) { OpenStruct.new(targets: [], players: []) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: []) }
  let(:target) { EngageNpc.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc') }
  let(:state) { EO::Engine::Engage::State.new }
  let(:tp) { EO::Engine::Targets::Policy.new }
  let(:buffs) { [] }

  before do
    active = buffs
    me.define_singleton_method(:effect_active?) { |n| active.any? { |b| n.is_a?(Regexp) ? b =~ n : b == n } }
    me.define_singleton_method(:buff_matching?) { |rx| active.any? { |b| b =~ rx } }
    me.define_singleton_method(:spell_active?) { |_n| false }
    me.define_singleton_method(:spell_effect_active?) { |_p| false }
    me.define_singleton_method(:cooldown_active?) { |_n| false }
    me.define_singleton_method(:debuff_active?) { |_n| false }
    me.define_singleton_method(:buff_time_left) { |_n| 0.0 }
  end

  def blocked(raw, **opts)
    line = EO::Engine::Engage::Routine.parse([raw]).first
    described_class.blocked_by(line, world, target, state, tp, **opts)
  end

  it 'passes a line with no modifiers' do
    expect(blocked('attack')).to be_nil
  end

  it 'reads the amount modifiers and their negations' do
    expect(blocked('1030 (m20)')).to be_nil
    me.mana = 19
    expect(blocked('1030 (m20)')).to eq('m20')
    expect(blocked('1030 (!m20)')).to be_nil
    me.mana = 20
    expect(blocked('1030 (!m20)')).to eq('!m20')
    room.targets = [target, EngageNpc.new(id: '2', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc')]
    expect(blocked('cman sweep (mob2)')).to be_nil
    expect(blocked('cman sweep (mob3)')).to eq('mob3')
  end

  it 'reads buff words, buff time, and the generic effects checks' do
    expect(blocked('barrage (barrage)')).to be_nil
    buffs << 'Enh. Dexterity (+10)'
    expect(blocked('barrage (barrage)')).to eq('barrage')
    expect(blocked('barrage (!barrage)')).to be_nil
    expect(blocked('barrage (buff30)')).to eq('buff30')
    me.define_singleton_method(:buff_time_left) { |_n| 5.0 }
    expect(blocked('barrage (buff30)')).to be_nil
    expect(blocked('attack (EB"Enh. Dex")')).to be_nil
    expect(blocked('attack (!EB"Enh. Dex")')).to eq('!EB"Enh. Dex"')
  end

  it "reads creature facts from Lich's creature instance" do
    statuses = []
    creature = OpenStruct.new
    creature.define_singleton_method(:has_status?) { |s| statuses.include?(s.to_s) }
    world.define_singleton_method(:creature) { |_id| creature }
    expect(blocked('cman trip (prone)')).to be_nil
    statuses << 'prone'
    expect(blocked('cman trip (prone)')).to eq('prone')
    expect(blocked('cman trip (!prone)')).to be_nil
    target.type = 'aggressive npc,undead'
    expect(blocked('smite (undead)')).to be_nil
    expect(blocked('smite (!undead)')).to eq('!undead')
  end

  it 'reads once, room and repeatdelay from the registry' do
    now = Time.at(10_000)
    expect(blocked('1030 (once)')).to be_nil
    state.register('1', '1030 (once)', now)
    expect(blocked('1030 (once)')).to eq('once')
    state.register('9', '1712 (room)', now)
    expect(blocked('1712 (room)')).to eq('room')
    state.register('9', '917 (repeatdelay10)', now)
    expect(blocked('917 (repeatdelay10)', now: now + 5)).to eq('repeatdelay10')
    expect(blocked('917 (repeatdelay10)', now: now + 11)).to be_nil
  end
end

RSpec.describe EO::Engine::Behaviors::Engage do
  def npc(id, name = 'kobold', noun: name.split.last, status: '')
    EngageNpc.new(id: id.to_s, name: name, noun: noun, status: status, type: 'aggressive npc')
  end

  let(:me) do
    OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, current_target_id: nil, hidden?: false,
                   mana: 100, stamina: 100, max_stamina: 100, spirit: 10, health_pct: 100, encumbrance_pct: 0, kneeling?: false,
                   profession: 'Warrior', moc_ranks: 0, diseased?: false, poisoned?: false, shadow_essence: 0)
  end
  let(:room) { OpenStruct.new(id: 1, targets: [npc(1), npc(2, 'orc')], players: [], title: '[Kobold Village]') }
  let(:spells) { {} }
  let(:world) { OpenStruct.new(me: me, room: room, spell: spells, claim_mine?: true, foreign_disks: [], group_nouns: []) }
  let(:policy) { EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack', '1030 (once)'], 'b' => ['cman bullrush'] }) }
  let(:tp) { EO::Engine::Targets::Policy.new(wanted: { 'kobold' => 'a', 'orc' => 'b' }) }
  let(:stances) { [] }
  let(:engage) { described_class.new(policy: policy, targets_policy: tp, stance: ->(s) { stances << s; true }) }
  let(:calls) { [] }

  before do
    %i[spell_active? cooldown_active? debuff_active? spell_effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
    me.define_singleton_method(:effect_active?) { |_n| false }
    me.define_singleton_method(:buff_matching?) { |_n| false }
    me.define_singleton_method(:buff_time_left) { |_n| 0.0 }
    ok = EO::Engine::Actions::Result.new(status: :success)
    log = calls
    { EO::Engine::Actions::Target => :target, EO::Engine::Actions::Attack => :attack, EO::Engine::Actions::Cast => :cast,
      EO::Engine::Actions::Maneuver => :maneuver, EO::Engine::Actions::Command => :command }.each do |klass, tag|
      allow(klass).to receive(:new) do |_w, **kw|
        t = kw[:target]
        log << [tag, kw.reject { |k, _| k == :target }.merge(t ? { target: t.respond_to?(:id) ? t.id : t } : {})]
        instance_double(klass, call: ok)
      end
    end
  end

  after { EO::Engine::Events.reset! }

  it 'wants control only in our room with a wanted creature' do
    expect(engage.wants_control?(world)).to be true
    world[:claim_mine?] = false
    expect(engage.wants_control?(world)).to be false
    world[:claim_mine?] = true
    room.targets = []
    expect(engage.wants_control?(world)).to be false
  end

  it 'marks a room combat-blocked when the game reports sanctuary' do
    policy.routines['a'] = ['702']
    spells[702] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 2, name: 'Mana Disruption')
    blocked = EO::Engine::Actions::Result.new(status: :failed, reason: :blocked,
                                              line: 'Be at peace my child, there is no need for spells of war in here.')
    allow(EO::Engine::Actions::Cast).to receive(:new).and_return(instance_double(EO::Engine::Actions::Cast, call: blocked))

    expect(engage.tick(world).reason).to eq(:blocked)
    expect(engage.state.combat_blocked_room).to eq(1)
    expect(engage.wants_control?(world)).to be(false)

    room.id = 2
    EO::Engine::Events.emit(:entered_room, room: 2)
    expect(engage.state.combat_blocked_room).to be_nil
  end

  it 'targets the creature, then runs its routine one line per tick with the hunting stance' do
    engage.tick(world)
    expect(calls.map(&:first)).to eq([:target, :attack])
    expect(calls[0].last[:target]).to eq('1')
    expect(calls[1].last[:command]).to eq('attack')
    expect(stances).to eq(['defensive'])
    spells[1030] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 10, name: 'x')
    me.current_target_id = '1'
    engage.tick(world)
    expect(calls.last).to eq([:cast, { spell: 1030, extra: nil, incant: false, target: '1' }])
    # the once line is registered, so the third tick wraps to attack and the fourth skips it
    engage.tick(world)
    skipped = engage.tick(world)
    expect(skipped.reason).to eq(:condition)
    expect(skipped.status).to eq(:skipped)
    expect(skipped.failed?).to be(false)
  end

  it 'casts a support spell on a named group member in the room' do
    policy.routines['a'] = ['allycast 117 Skooshii']
    spells[117] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 15, name: 'Spirit Strike')
    room.players = [OpenStruct.new(noun: 'Skooshii', name: 'Skooshii')]
    world.group_nouns = ['Skooshii']

    engage.tick(world)

    expect(calls.last).to eq([:cast, { spell: 117, target: 'Skooshii' }])
  end

  it 'rearms an afterattack ally cast only when that named ally attacks' do
    policy.routines['a'] = ['allycast 117 Skooshii (afterattack)']
    spells[117] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 15, name: 'Spirit Strike')
    room.players = [OpenStruct.new(noun: 'Skooshii', name: 'Skooshii')]
    world.group_nouns = ['Skooshii']
    me.current_target_id = '1'

    expect(engage.tick(world).status).to eq(:success)
    expect(engage.tick(world).reason).to eq(:awaiting_ally_attack)
    expect(calls.count { |tag, _| tag == :cast }).to eq(1)

    EO::Engine::Events.emit(:ally_attacked, name: 'SomeoneElse')
    expect(engage.tick(world).reason).to eq(:awaiting_ally_attack)

    EO::Engine::Events.emit(:ally_attacked, name: 'skooshii')
    expect(engage.tick(world).status).to eq(:success)
    expect(calls.count { |tag, _| tag == :cast }).to eq(2)
  end

  it 'skips an ally cast when that group member is not in the room' do
    policy.routines['a'] = ['allycast 117 Skooshii']
    spells[117] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 15, name: 'Spirit Strike')
    world.group_nouns = ['Skooshii']

    result = engage.tick(world)

    expect(result.status).to eq(:skipped)
    expect(result.reason).to eq(:ally_missing)
    expect(calls.none? { |tag, _| tag == :cast }).to be(true)
  end

  it 'casts kweed as an evoked 610 unless a weed is already down' do
    policy.routines['a'] = ['kweed(buff5)']
    spells[610] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 10, name: 'Tangleweed')
    engage.tick(world)
    expect(calls.last).to eq([:cast, { spell: 610, extra: 'evoke', target: '1' }])
    room.loot = [OpenStruct.new(name: 'a thorny vine', noun: 'vine')]
    me.current_target_id = '1'
    expect(engage.tick(world).reason).to eq(:weed_present)
  end

  it 'picks the routine letter by the targets list' do
    room.targets = [npc(2, 'orc')]
    engage.tick(world)
    expect(calls.last).to eq([:maneuver, { category: :cman, name: 'Bull Rush', skip_if_buff: false, target: '2' }])
  end

  it 'learns an untargetable name from the probe and moves on' do
    refused = EO::Engine::Actions::Result.new(status: :failed, reason: :untargetable)
    allow(EO::Engine::Actions::Target).to receive(:new).and_return(instance_double(EO::Engine::Actions::Target, call: refused))
    learned = []
    EO::Engine::Events.on(:untargetable_learned) { |e| learned << e.data[:name] }
    expect(engage.tick(world).reason).to eq(:untargetable)
    expect(learned).to eq(['kobold'])
    expect(tp.untargetable_set).to eq(['kobold'])
    expect(engage.wants_control?(world)).to be true
    expect(engage.send(:next_target, world).id).to eq('2')
  end

  it 'does not blacklist a species when an ally kills the target during the target probe' do
    refused = EO::Engine::Actions::Result.new(status: :failed, reason: :untargetable, line: "You can't target a kobold.")
    probe = instance_double(EO::Engine::Actions::Target)
    allow(EO::Engine::Actions::Target).to receive(:new).and_return(probe)
    allow(probe).to receive(:call) do
      room.targets.first.status = 'dead'
      refused
    end
    learned = []
    EO::Engine::Events.on(:untargetable_learned) { |e| learned << e.data[:name] }

    result = engage.tick(world)

    expect(result.status).to eq(:skipped)
    expect(result.reason).to eq(:target_gone)
    expect(learned).to be_empty
    expect(tp.untargetable_set).to be_empty
  end

  it 'switches to a better-ranked creature only with priority on' do
    room.targets = [npc(2, 'orc'), npc(1)]
    tp = EO::Engine::Targets::Policy.new(wanted: { 'kobold' => 'a', 'orc' => 'b' })
    plain = described_class.new(policy: policy, targets_policy: tp, stance: ->(_s) { true })
    plain.tick(world)
    expect(plain.target.id).to eq('1')
    room.targets.unshift(npc(3, 'kobold'))
    plain.tick(world)
    expect(plain.target.id).to eq('1')
    policy.priority = true
    room.targets = [npc(2, 'orc')]
    pri = described_class.new(policy: policy, targets_policy: tp, stance: ->(_s) { true })
    pri.tick(world)
    expect(pri.target.id).to eq('2')
    room.targets << npc(4, 'kobold')
    pri.tick(world)
    expect(pri.target.id).to eq('4')
  end

  it 'assesses a pending boon creature as the tick\'s action before fighting, then fights by what it learned' do
    boon = EngageNpc.new(id: '7', name: 'slimy kobold', noun: 'kobold', status: '', type: 'aggressive npc,boon')
    assessed = []
    cache = EO::Engine::Targets::BoonCache.new(nil, assess: ->(c) { assessed << c.id; EO::Engine::Actions::Result.new(status: :success, line: 'It appears to be slimy.') })
    tp.boons_ignore = ['regen']
    tp.boon_abilities = cache
    room.targets = [boon]
    expect(engage.wants_control?(world)).to be true # unknown is not excluded, and nothing was sent
    expect(assessed).to be_empty
    expect(engage.tick(world)).to be_success
    expect(assessed).to eq(['7'])
    expect(calls).to be_empty
    expect(engage.wants_control?(world)).to be false # a regen boon on the ignore list
  end

  it 'waves the wand in the spell\'s place when out of mana with wand_if_oom' do
    policy.routines['a'] = ['1030']
    policy.wand_if_oom = true
    spells[1030] = OpenStruct.new(known?: true, affordable?: false, active?: false, mana_cost: 10, name: 'x')
    waved = EO::Engine::Actions::Result.new(status: :success, reason: :waved)
    wand = instance_double(EO::Engine::Actions::Wand, call: waved)
    expect(EO::Engine::Actions::Wand).to receive(:new).with(world, target: room.targets.first, policy: policy, state: engage.state, stance: engage.stance).and_return(wand)
    expect(engage.tick(world)).to equal(waved)
    expect(calls.map(&:first)).not_to include(:cast)
  end

  it 'gates a spell the way cmd_spell does and reports out of mana' do
    policy.routines['a'] = ['1030']
    spells[1030] = OpenStruct.new(known?: true, affordable?: false, active?: false, mana_cost: 10, name: 'x')
    oom = []
    EO::Engine::Events.on(:out_of_mana) { |e| oom << e.data[:spell] }
    expect(engage.tick(world).reason).to eq(:out_of_mana)
    expect(oom).to eq([1030])
    policy.oom = -1
    engage.tick(world)
    expect(oom.size).to eq(1)
  end

  it 'routes a routines.rb word, a warcry ALL, and falls through to a bare command' do
    policy.routines['a'] = ['wield sword', 'growl all', 'search']
    world[:hands] = OpenStruct.new(right: OpenStruct.new(id: '1', noun: 'katana'), left: OpenStruct.new(id: nil, noun: ''))
    me.define_singleton_method(:inventory_nouns) { ['sword'] }
    wielded = []
    allow_any_instance_of(EO::Engine::Actions::Wield).to receive(:send_through_ladder) { |_a, cmd| wielded << cmd; 'ok' }
    expect(engage.tick(world).reason).to eq(:wielded)
    expect(wielded).to eq(['store right', 'remove my sword'])
    engage.tick(world)
    expect(calls.last).to eq([:maneuver, { category: :warcry, name: 'growl', skip_if_buff: false, target: 'all' }])
    engage.tick(world)
    expect(calls.last).to eq([:command, { command: 'search' }])
  end

  it 'forgets the room registry and the target on a new room' do
    engage.tick(world)
    engage.state.register('1', 'x')
    EO::Engine::Events.emit(:entered_room, room: 2)
    expect(engage.state.registry).to be_empty
    expect(engage.target).to be_nil
  end
end
