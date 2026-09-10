# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

# A stand-in for Spell[n]: every gate cast_signs reads.
FakeSpell = Struct.new(:num, :name, :known, :active, :affordable, :mana_cost, :last_cast, keyword_init: true) do
  def known? = known
  def active? = active
  def affordable? = affordable
  def cast(*_args) = (@casts = (@casts || 0) + 1; 'Cast Roundtime 3 Seconds.')
  def force_channel(*_args) = cast
  def casts = @casts || 0
end unless defined?(FakeSpell)

RSpec.describe EO::Engine::Maintain::Signs do
  let(:me) do
    OpenStruct.new(mana: 100, stamina: 100, max_stamina: 100, spirit: 10, level: 50, voln_favor: 100_000, blessings_ranks: 0,
                   dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, profession: 'Warrior')
  end
  let(:spells) { {} }
  let(:world) { OpenStruct.new(me: me, spell: spells) }
  let(:policy) { EO::Engine::Maintain::Policy.new }
  let(:state) { EO::Engine::Maintain::State.new }
  let(:now) { Time.at(10_000) }

  def spell(num, **over)
    spells[num] = FakeSpell.new(num: num, name: "Spell #{num}", known: true, active: false, affordable: true, mana_cost: 10, last_cast: now - 60, **over)
  end

  before do
    table = spells
    me.define_singleton_method(:spell_active?) { |n| table[n]&.active? || false }
    me.define_singleton_method(:effect_active?) { |_n| false }
    me.define_singleton_method(:cooldown_active?) { |_n| false }
    me.define_singleton_method(:buff_time_left) { |_n| 0.0 }
  end

  def due(entry) = described_class.due(world, described_class.parse([entry]).first, policy, state, now: now)

  it 'parses the special entries' do
    kinds = described_class.parse(['650 lion wolf', 'rapid', '515 (ignore)', '122420', '9605', '9625', '909', '902', '411', '1712']).map(&:kind)
    expect(kinds).to eq(%i[assume rapid rapid shout surge burst channel bless_902 bless_411 spell])
  end

  it 'assumes an aspect when 650 is ready and neither aspect is up or fully cooling down' do
    expect(due('650 panther evoke')).to be_nil
    spell(650)
    expect(due('650 panther evoke')).to eq(:assume)
    effects = ['Aspect of the Panther']
    me.define_singleton_method(:effect_active?) { |n| effects.include?(n) }
    expect(due('650 panther evoke')).to be_nil
    effects.clear
    cooling = ['Aspect of the Lion Cooldown', 'Aspect of the Wolf Cooldown']
    me.define_singleton_method(:spell_active?) { |n| cooling.include?(n) }
    expect(due('650 lion wolf')).to be_nil
    expect(due('650 lion evoke')).to eq(:assume)
  end

  it 'casts a known, inactive, affordable spell after the 1.5 s spacing' do
    spell(1712)
    expect(due('1712')).to eq(:cast)
    spells[1712].active = true
    expect(due('1712')).to be_nil
    spells[1712].active = false
    spells[1712].last_cast = now - 1
    expect(due('1712')).to be_nil
  end

  it 'applies the skips: unknown, 9918, Voln symbols under 9012, 597 penalty, cooldowns, favor' do
    spell(9904); spell(9012, active: true)
    expect(due('9904')).to be_nil
    spell(9918)
    expect(due('9918')).to be_nil
    spell(597, active: true); spell(1712, mana_cost: 96)
    expect(due('1712')).to be_nil
    spell(605)
    me.define_singleton_method(:cooldown_active?) { |n| n == 'Barkskin' }
    expect(due('605')).to be_nil
    spell(211, name: 'Spirit Warding I')
    me.define_singleton_method(:cooldown_active?) { |n| n == 'Spirit Warding I' }
    expect(due('211')).to be_nil
    spell(9816); policy.check_favor = true; me.voln_favor = 0
    expect(due('9816')).to be_nil
  end

  it 'wracks for an unaffordable sign when wracking is on, else skips it' do
    spell(1712, affordable: false, mana_cost: 50); me.mana = 10
    expect(due('1712')).to be_nil
    policy.use_wracking = true
    expect(due('1712')).to eq(:wrack)
  end

  it 'holds a Bard below the renewal cost' do
    spell(1712)
    me.mana = 15
    expect(described_class.due(world, described_class.parse(['1712']).first, policy, state, now: now, renewal_cost: 10)).to be_nil
  end

  it 'gates rapid fire on the buff, the recovery cooldown and the ignore word' do
    spell(515)
    expect(due('rapid')).to eq(:cast)
    me.define_singleton_method(:cooldown_active?) { |n| n == 'Rapid Fire Recovery' }
    expect(due('rapid')).to be_nil
    expect(due('rapid (ignore)')).to eq(:cast)
  end

  it 'gates the weapon blesses on the look result' do
    spell(902); spell(411)
    expect(due('902')).to eq(:cast)
    state.blessed_902 = true
    expect(due('902')).to be_nil
    expect(due('411')).to eq(:cast)
  end

  it 'gates surge, burst and the shout on stamina and cooldowns' do
    expect(due('9605')).to eq(:maneuver)
    me.stamina = 29
    expect(due('9625')).to be_nil
    me.stamina = 100
    me.define_singleton_method(:buff_time_left) { |n| n == 'Empowered (+20)' ? 5.0 : 0.0 }
    expect(due('122420')).to be_nil
  end
end

RSpec.describe EO::Engine::Maintain::Stamina do
  let(:me) { OpenStruct.new(profession: 'Paladin', stamina: 40, max_stamina: 120, blessings_ranks: 40) }
  let(:spells) { {} }
  let(:world) { OpenStruct.new(me: me, spell: spells) }
  let(:state) { EO::Engine::Maintain::State.new }

  def spell(num, **over)
    spells[num] = FakeSpell.new(num: num, name: "Spell #{num}", known: true, active: false, affordable: true, mana_cost: 10, last_cast: Time.at(0), **over)
  end

  before do
    table = spells
    me.define_singleton_method(:spell_active?) { |n| table[n]&.active? || false }
  end

  it 'is nothing for other professions' do
    me.profession = 'Rogue'
    spell(1607)
    expect(described_class.top_up_spell(world, floor: 100, state: state)).to be_nil
  end

  it 'picks Rejuvenation when its gain reaches the floor' do
    spell(1607)
    # 40 ranks -> 8 steps -> +15 + 24 = 79
    expect(described_class.top_up_spell(world, floor: 79, state: state)).to eq(1607)
    expect(described_class.top_up_spell(world, floor: 80, state: state)).to be_nil
  end

  it 'picks Adrenal Surge by the estimated gain, once every 301 seconds' do
    spell(1107)
    now = Time.at(10_000)
    expect(described_class.top_up_spell(world, floor: 90, state: state, now: now)).to eq(1107)
    state.adrenal_at = now
    expect(described_class.top_up_spell(world, floor: 90, state: state, now: now + 10)).to be_nil
    expect(described_class.top_up_spell(world, floor: 91, state: state, now: now + 400)).to be_nil
    me.blessings_ranks = 65
    expect(described_class.top_up_spell(world, floor: 120, state: state, now: now + 400)).to eq(1107)
  end
end

RSpec.describe EO::Engine::Actions::Wrack do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, spirit: 10, stamina: 120, mana: 10) }
  let(:world) { OpenStruct.new(me: me) }
  let(:sent) { [] }
  let(:col) { double('CouncilOfLight', name: 'Lich::Gemstone::Society::CouncilOfLight') }
  let(:sunfist) { double('GuardiansOfSunfist', name: 'Lich::Gemstone::Society::GuardiansOfSunfist') }
  let(:voln) { double('OrderOfVoln', name: 'Lich::Gemstone::Society::OrderOfVoln') }

  def wrack(policy: EO::Engine::Maintain::Policy.new, col_ok: false, sunfist_ok: false, voln_ok: false)
    allow(col).to receive(:available?).with('wracking').and_return(col_ok)
    allow(col).to receive(:[]).and_return({ short_name: 'wracking' })
    allow(sunfist).to receive(:available?).with('power') { sunfist_ok && me.stamina >= 50 }
    allow(sunfist).to receive(:[]).and_return({ short_name: 'power' })
    allow(voln).to receive(:available?).with('mana').and_return(voln_ok)
    allow(voln).to receive(:[]).and_return({ short_name: 'mana' })
    action = described_class.new(world, policy: policy, timeout: 0.05)
    allow(action).to receive(:col).and_return(col)
    allow(action).to receive(:sunfist).and_return(sunfist)
    allow(action).to receive(:voln).and_return(voln)
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; me.mana += 20; me.stamina -= 50 if cmd =~ /sigil/; 'ok' }
    allow(action).to receive(:sleep)
    action
  end

  before do
    me.define_singleton_method(:spell_active?) { |_n| false }
    me.define_singleton_method(:cooldown_active?) { |_n| false }
  end

  it 'wracks when the reader allows and the spirit floor is met' do
    expect(wrack(col_ok: true, policy: EO::Engine::Maintain::Policy.new(wracking_spirit: 8)).call.reason).to eq(:wracking)
    expect(sent).to eq(['sign of wracking'])
    me.spirit = 6
    expect(wrack(col_ok: true, policy: EO::Engine::Maintain::Policy.new(wracking_spirit: 8)).call.reason).to eq(:no_wrack)
  end

  it 'uses the sigil while affordable, else the symbol' do
    expect(wrack(sunfist_ok: true).call.reason).to eq(:sigil_of_power)
    expect(sent).to eq(['sigil of power', 'sigil of power'])
    sent.clear
    expect(wrack(voln_ok: true).call.reason).to eq(:symbol_of_mana)
    expect(sent).to eq(['symbol of mana'])
  end
end

RSpec.describe EO::Engine::Maintain::Briar do
  let(:briar) { FakeSpell.new(num: 9105, name: 'Briar Betrayer', known: true, active: false, affordable: true, mana_cost: 0, last_cast: Time.at(0)) }

  before do
    stub_const('Spell', Class.new { def self.[](_n); end })
    allow(Spell).to receive(:[]).with(9105).and_return(briar)
    briar.define_singleton_method(:timeleft=) { |v| @timeleft = v }
    briar.define_singleton_method(:timeleft) { @timeleft }
    briar.define_singleton_method(:putdown) { @timeleft = 0; self[:active] = false }
    EO::Engine::Behaviors::Maintain.new(policy: EO::Engine::Maintain::Policy.new) # installs the event handlers
    described_class.watch! # another spec may have cleared the watch
  end

  after { EO::Engine::Events.reset!; EO::Engine::Watch.clear!; described_class.watch! }

  it 'marks 9105 up for two minutes on the raise pulse and down on the end line' do
    EO::Engine::Watch.process('As you begin to raise your ruic longbow, the briars imbedded in your flesh release their stored blood in a massive pulse of power that you can feel in the core of your very being.  The vines lose all crimson hues, and strength courses through your blood.')
    expect(briar.active).to be true
    expect(briar.timeleft).to eq(2.0)
    EO::Engine::Watch.process('You no longer look stronger.')
    expect(briar.active).to be false
    expect(briar.timeleft).to eq(0)
  end

  it 'does nothing without a Spell 9105' do
    allow(Spell).to receive(:[]).with(9105).and_return(nil)
    expect { EO::Engine::Watch.process('You no longer look stronger.') }.not_to raise_error
  end
end

RSpec.describe EO::Engine::Behaviors::Maintain do
  let(:me) do
    OpenStruct.new(mana: 100, stamina: 100, max_stamina: 100, spirit: 10, level: 50, voln_favor: 0, blessings_ranks: 0,
                   dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, profession: 'Cleric')
  end
  let(:spells) { {} }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(id: '77', noun: 'katana'), left: OpenStruct.new(id: nil, noun: '')) }
  let(:world) { OpenStruct.new(me: me, spell: spells, hands: hands) }
  let(:policy) { EO::Engine::Maintain::Policy.new(signs: ['1712', '902']) }
  let(:maintain) { described_class.new(policy: policy) }

  def spell(num, **over)
    spells[num] = FakeSpell.new(num: num, name: "Spell #{num}", known: true, active: false, affordable: true, mana_cost: 10, last_cast: Time.at(0), **over)
  end

  before do
    table = spells
    me.define_singleton_method(:spell_active?) { |n| table[n]&.active? || false }
    me.define_singleton_method(:effect_active?) { |_n| false }
    me.define_singleton_method(:cooldown_active?) { |_n| false }
    me.define_singleton_method(:buff_time_left) { |_n| 0.0 }
    stub_const('Spell', Class.new { def self.[](_n); end })
    allow(Spell).to receive(:[]) { |n| spells[n] }
    allow_any_instance_of(EO::Engine::Actions::WeaponBlessCheck).to receive(:look_at).and_return(['The katana gleams faintly with inner light.'])
  end

  after { EO::Engine::Events.reset! }

  it 'casts one due sign per tick, in list order, and stops when all are up' do
    spell(1712); spell(902)
    expect(maintain.wants_control?(world)).to be true
    expect(maintain.tick(world)).to be_success
    expect(spells[1712].casts).to eq(1)
    spells[1712].active = true
    maintain.wants_control?(world)
    maintain.tick(world)
    expect(spells[902].casts).to eq(1)
    expect(maintain.state.blessed_902).to be true
    expect(maintain.wants_control?(world)).to be false
  end

  it 'blesses a weapon the watch reported before any sign' do
    spell(1712); spell(304)
    EO::Engine::Events.emit(:bless_expired, id: '77')
    expect(maintain.wants_control?(world)).to be true
    result = maintain.tick(world)
    expect(result).to be_success # bless is off: the sign ran, not the bless
    expect(spells[1712].casts).to eq(1)
    policy.bless = true
    other = described_class.new(policy: policy)
    EO::Engine::Events.emit(:bless_expired, id: '77')
    expect(other.tick(world).reason).to eq(:spell_304)
    expect(spells[304].casts).to eq(1)
    expect(other.state.bless_wanted).to be_empty
  end

  it 'reports when there is no blessing to give' do
    policy.bless = true
    stuck = []
    EO::Engine::Events.on(:maintain_stuck) { |e| stuck << e.data[:reason] }
    blesser = described_class.new(policy: policy)
    EO::Engine::Events.emit(:bless_shrugged, id: '77', noun: 'katana', mine: true)
    expect(blesser.tick(world).reason).to eq(:no_blessing)
    expect(stuck).to eq(['No blessing on weapon'])
    expect(blesser.state.bless_wanted).to be_empty
  end

  it 'only takes a shrugged hit on our own item or ammo' do
    policy.bless = true
    policy.ammo = 'arrow'
    blesser = described_class.new(policy: policy)
    EO::Engine::Events.emit(:bless_shrugged, id: '1', noun: 'sword', mine: false)
    EO::Engine::Events.emit(:bless_shrugged, id: '2', noun: 'arrow', mine: false)
    expect(blesser.state.bless_wanted).to eq(['2'])
  end
end
