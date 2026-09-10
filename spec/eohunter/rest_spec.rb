# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Rest do
  let(:me) do
    OpenStruct.new(fxp_pct: 50, mana_pct: 95, spirit: 10, stamina_pct: 90, encumbrance_pct: 10,
                   dead?: false, debuffs: {})
  end
  let(:policy) do
    described_class::Policy.new(fried: 95, overkill: 2, lte_boost: 1, oom: 20, encumbered: 60,
                                creeping_dread: 3, crushing_dread: 2, wot_poison: true, confusion: true,
                                rest_till_exp: 80, rest_till_mana: 90, rest_till_spirit: 8, rest_till_stamina: 70)
  end
  let(:counters) { described_class::Counters.new }

  before do
    debuffs = me.debuffs
    me.define_singleton_method(:debuff_level) { |name| debuffs[name] }
    me.define_singleton_method(:debuff_active?) { |name| debuffs.key?(name) }
  end

  describe 'Predicates.rest_reason' do
    def reason = described_class::Predicates.rest_reason(me, policy, counters)

    it 'is nil when nothing calls for a rest' do
      expect(reason).to be_nil
    end

    it 'takes a forced reason first' do
      expect(described_class::Predicates.rest_reason(me, policy, counters, forced: 'Could not reach 8003')).to eq('Could not reach 8003')
    end

    it 'rests wounded by the profile eval' do
      policy.wounded = -> { true }
      expect(reason).to eq('wounded.')
    end

    it 'rests fried only after the boosts are spent and the extra kills are in' do
      me.fxp_pct = 96
      expect(reason).to be_nil
      counters.lte_boosts = 1
      expect(reason).to be_nil
      counters.overkill = 2
      expect(reason).to eq('fried.')
    end

    it 'never rests fried when the threshold is above 100' do
      policy.fried = 101
      me.fxp_pct = 110
      counters.lte_boosts = 1
      counters.overkill = 5
      expect(reason).to be_nil
    end

    it 'rests on encumbrance, dread levels, thorns poison, confusion and mana, in that order' do
      me.encumbrance_pct = 60
      expect(reason).to eq('encumbered.')
      me.encumbrance_pct = 0
      me.debuffs['Creeping Dread'] = 3
      expect(reason).to eq('creeping dread limit.')
      me.debuffs.clear
      me.debuffs['Crushing Dread'] = 1
      expect(reason).to be_nil
      me.debuffs['Crushing Dread'] = 2
      expect(reason).to eq('crushing dread limit.')
      me.debuffs.clear
      me.debuffs['Wall of Thorns Poison'] = 1
      expect(reason).to eq('wall of thorns poison.')
      me.debuffs.clear
      me.debuffs['Confused'] = 1
      expect(reason).to eq('confusion debuff.')
      me.debuffs.clear
      me.mana_pct = 19
      expect(reason).to eq('out of mana.')
    end

    it 'ignores mana when oom is negative' do
      policy.oom = -1
      me.mana_pct = 0
      expect(reason).to be_nil
    end
  end

  describe 'Predicates.not_hunting_reason' do
    def why = described_class::Predicates.not_hunting_reason(me, policy)

    it 'is nil when every rest_till threshold is met' do
      expect(why).to be_nil
    end

    it 'names the first unmet threshold' do
      me.fxp_pct = 81
      expect(why).to eq('mind still above threshold.')
      me.fxp_pct = 80
      me.mana_pct = 89
      expect(why).to eq('mana still below threshold.')
      me.mana_pct = 90
      me.spirit = 7
      expect(why).to eq('spirit still below threshold.')
      me.spirit = 8
      me.stamina_pct = 69
      expect(why).to eq('stamina still below threshold.')
    end

    it 'waits for resting scripts' do
      expect(described_class::Predicates.not_hunting_reason(me, policy, scripts_running: ['eherbs'])).to eq('resting scripts are still running.')
    end
  end
end

RSpec.describe EO::Engine::Behaviors::Rest do
  let(:me) { OpenStruct.new(fxp_pct: 50, mana_pct: 80, spirit: 10, stamina_pct: 90, encumbrance_pct: 10, dead?: false, in_rt?: false, in_cast_rt?: false) }
  let(:world) { OpenStruct.new(me: me) }
  let(:policy) do
    EO::Engine::Rest::Policy.new(oom: 20, rest_till_mana: 90, rest_till_exp: 100, resting_room: 100, return_waypoints: [1, 2],
                                 hunting_room: 200, rally_rooms: [3], fog_return: 1,
                                 resting_commands: ['sit'], resting_scripts: ['eherbs'],
                                 hunting_prep_commands: ['stand'], hunting_scripts: ['eloot'],
                                 wander_stance: 'defensive', rest_interval: 0)
  end
  let(:trips) { [] }
  let(:fogged) { [] }
  let(:stances) { [] }
  let(:scripts) do
    Class.new do
      attr_reader :started, :killed

      def initialize = (@started = []; @killed = []; @running = [])
      def start(name, args) = @started << [name, args]
      def running?(name) = @running.include?(name)
      def kill(name) = @killed << name
      def run!(name) = @running << name
      def stop!(name) = @running.delete(name)
    end.new
  end
  let(:rest) do
    described_class.new(policy: policy, travel: ->(r) { trips << r; true }, fog: ->(_p, _r) { fogged << true; true },
                        scripts: scripts, stance: ->(s) { stances << s; true })
  end

  before do
    me.define_singleton_method(:debuff_level) { |_n| nil }
    me.define_singleton_method(:debuff_active?) { |_n| false }
    allow(rest).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:send_through_ladder).and_return('ok')
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:sleep)
  end

  def run_until(phase, limit: 40)
    limit.times do
      rest.tick(world)
      return if rest.phase == phase
    end
    raise "never reached #{phase}, at #{rest.phase}"
  end

  it 'does not want control while nothing calls for a rest' do
    expect(rest.wants_control?(world)).to be false
    expect(rest.resting?).to be false
  end

  it 'wants control on a rest reason and keeps it through the cycle' do
    me.mana_pct = 10
    expect(rest.wants_control?(world)).to be true
    rest.tick(world)
    me.mana_pct = 100
    expect(rest.wants_control?(world)).to be true
  end

  it 'walks the whole cycle one step per tick' do
    me.mana_pct = 10
    rest.wants_control?(world)
    scripts.run!('eloot')
    rest.tick(world) # begin
    expect(rest.phase).to eq(:leave)
    rest.tick(world) # leave: kill hunting scripts, wander stance
    expect(scripts.killed).to eq(['eloot'])
    expect(stances).to eq(['defensive'])
    rest.tick(world) # fog
    expect(fogged.size).to eq(1)
    run_until(:resting_room)
    expect(trips).to eq([1, 2])
    run_until(:resting_prep)
    expect(trips.last).to eq(100)
    run_until(:resting)
    expect(scripts.started).to eq([['eherbs', nil]])
    me.mana_pct = 50
    rest.tick(world) # still resting: mana below rest_till_mana
    expect(rest.phase).to eq(:resting)
    me.mana_pct = 95
    rest.tick(world)
    expect(rest.phase).to eq(:hunting_prep)
    run_until(:rally)
    expect(scripts.started.last).to eq(['eloot', nil])
    run_until(:hunting_room)
    expect(trips.last).to eq(3)
    run_until(:done)
    expect(trips.last).to eq(200)
    rest.tick(world)
    expect(rest.phase).to eq(:hunting)
    expect(rest.resting?).to be false
  end

  it 'skips the fog when the profile turns it off, or when optional and the reason is not wounds or weight' do
    policy.fog_return = 0
    me.mana_pct = 10
    rest.wants_control?(world)
    rest.tick(world)
    rest.tick(world)
    rest.tick(world)
    expect(fogged).to be_empty
    policy.fog_return = 1
    policy.fog_optional = true
    other = described_class.new(policy: policy, travel: ->(_r) { true }, fog: ->(_p, _r) { fogged << true; true }, scripts: scripts, stance: ->(_s) { true })
    other.wants_control?(world)
    3.times { other.tick(world) }
    expect(fogged).to be_empty
  end

  it 'gives a room five tries, then records being stuck' do
    me.mana_pct = 10
    stuck = described_class.new(policy: policy, travel: ->(r) { trips << r; r != 100 }, fog: ->(_p, _r) { true }, scripts: scripts, stance: ->(_s) { true })
    allow(stuck).to receive(:sleep)
    stuck.wants_control?(world)
    seen = []
    EO::Engine::Events.on(:rest_stuck) { |e| seen << e.data[:room] }
    12.times { stuck.tick(world) }
    expect(trips.count(100)).to eq(5)
    expect(seen).to eq([100])
    expect(stuck.phase).to eq(:resting)
  ensure
    EO::Engine::Events.reset!
  end

  it 'starts a hunt with the prep, the rally rooms and the hunting room' do
    rest.start!
    expect(rest.wants_control?(world)).to be true
    run_until(:done)
    expect(trips).to eq([3, 200])
    expect(scripts.started).to eq([['eloot', nil]])
    rest.tick(world)
    expect(rest.resting?).to be false
  end

  it 'takes a forced reason from outside' do
    rest.rest!('Unknown result from fire routine')
    expect(rest.wants_control?(world)).to be true
    rest.tick(world)
    expect(rest.reason).to eq('Unknown result from fire routine')
  end

  describe 'the final loot' do
    let(:loot) do
      Class.new do
        attr_reader :final, :ticks

        def initialize(wants) = (@wants = wants; @ticks = 0; @final = false)
        def final! = @final = true
        def wants_control?(_w) = @wants.positive?
        def tick(_w) = (@wants -= 1; @ticks += 1; EO::Engine::Actions::Result.new(status: :success))
      end
    end
    let(:with_loot) do
      described_class.new(policy: policy, travel: ->(r) { trips << r; true }, fog: ->(_p, _r) { true },
                          scripts: scripts, stance: ->(s) { stances << s; true }, loot: looter)
    end

    context 'with two corpses to loot' do
      let(:looter) { loot.new(2) }

      it 'drives Loot before leaving, for a mana rest' do
        me.mana_pct = 10
        with_loot.wants_control?(world)
        with_loot.tick(world) # begin
        expect(looter.final).to be true
        expect(with_loot.phase).to eq(:final_loot)
        expect(with_loot.tick(world)).to be_success
        expect(with_loot.tick(world)).to be_success
        expect(stances).to be_empty # not left yet
        with_loot.tick(world)
        expect(with_loot.phase).to eq(:leave)
        expect(looter.ticks).to eq(2)
      end

      it 'skips the loot for a wounded rest or one outside bigshot\'s reasons' do
        policy.wounded = -> { true }
        with_loot.wants_control?(world)
        with_loot.tick(world)
        expect(with_loot.phase).to eq(:leave)
        expect(looter.final).to be false
        other = loot.new(2)
        forced = described_class.new(policy: policy, travel: ->(_r) { true }, fog: ->(_p, _r) { true }, scripts: scripts, stance: ->(_s) { true }, loot: other)
        policy.wounded = nil
        forced.rest!('Could not reach 100')
        forced.wants_control?(world)
        forced.tick(world)
        expect(forced.phase).to eq(:leave)
        expect(other.final).to be false
      end
    end

    context 'with a loot that never finishes' do
      let(:looter) { loot.new(1_000) }

      it 'leaves after the cap' do
        me.mana_pct = 10
        with_loot.wants_control?(world)
        with_loot.tick(world)
        (described_class::FINAL_LOOT_TICKS + 1).times { with_loot.tick(world) }
        expect(with_loot.phase).to eq(:leave)
        expect(looter.ticks).to eq(described_class::FINAL_LOOT_TICKS)
      end
    end
  end
end

RSpec.describe EO::Engine::Actions::LteBoost do
  let(:me) { OpenStruct.new(fxp_pct: 96, dead?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false) }
  let(:world) { OpenStruct.new(me: me) }
  let(:policy) { EO::Engine::Rest::Policy.new(fried: 95, lte_boost: 2) }
  let(:counters) { EO::Engine::Rest::Counters.new(overkill: 3) }

  def boost(reply)
    action = described_class.new(world, counters: counters, policy: policy)
    queue = []
    allow(action).to receive(:game_put) { queue << reply }
    allow(action).to receive(:clear_lines) { queue.clear }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |l| queue.unshift(l) }
    allow(action).to receive(:sleep)
    allow(action).to receive(:live_target_ids).and_return(nil)
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  it 'redeems a boost, counting it and clearing the extra kills' do
    expect(boost('You have deducted 500 experience points from your field experience.').call).to be_success
    expect(counters.lte_boosts).to eq(1)
    expect(counters.overkill).to eq(0)
  end

  it 'marks every boost spent when none are left' do
    result = boost('You do not have any Long-Term Experience Boosts to redeem.').call
    expect(result.reason).to eq(:none_left)
    expect(counters.lte_boosts).to eq(2)
  end

  it 'refuses when not fried or when the boosts are already spent' do
    me.fxp_pct = 50
    expect(boost('x').call.reason).to eq(:not_fried)
    me.fxp_pct = 96
    counters.lte_boosts = 2
    expect(boost('x').call.reason).to eq(:none_left)
  end
end
