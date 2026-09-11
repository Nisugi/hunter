# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Loot::Predicates do
  def npc(id, status: '', type: 'aggressive npc')
    OpenStruct.new(id: id.to_s, name: 'kobold', noun: 'kobold', status: status, type: type)
  end

  let(:room) { OpenStruct.new(title: '[Kobold Village]', creatures: [], targets: [], loot: []) }
  let(:world) { OpenStruct.new(room: room, claim_mine?: true) }
  let(:tp) { EO::Engine::Targets::Policy.new }
  let(:policy) { EO::Engine::Loot::Policy.new }

  def reason(**opts) = described_class.reason(world, tp, policy, **opts)

  it 'wants a corpse, ignoring escorts and looted ones' do
    expect(reason).to be_nil
    room.creatures = [npc(1, status: 'dead'), npc(2, status: 'dead', type: 'escort')]
    expect(reason).to eq(:corpses)
    expect(reason(looted: ['1'])).to be_nil
  end

  it 'never loots without the claim or in an arena or escape room' do
    room.creatures = [npc(1, status: 'dead')]
    world[:claim_mine?] = false
    expect(reason).to be_nil
    world[:claim_mine?] = true
    room.title = '[The Belly of the Beast]'
    expect(reason).to be_nil
  end

  it 'delays while something is still up, unless final' do
    policy.delay = true
    room.creatures = [npc(1, status: 'dead')]
    room.targets = [npc(2)]
    now = Time.at(1000)
    expect(reason(now: now)).to eq(:corpses)
    expect(reason(now: now, last_at: now - 5)).to be_nil
    expect(reason(now: now, last_at: now - 15)).to eq(:corpses)
    expect(reason(now: now, last_at: now - 5, final: true)).to eq(:corpses)
  end

  it 'loots the floor only on a final loot with nothing to fight' do
    room.loot = [OpenStruct.new(noun: 'coins')]
    expect(reason).to be_nil
    expect(reason(final: true)).to eq(:floor)
    room.targets = [npc(2)]
    expect(reason(final: true)).to be_nil
  end

  it "counts only objects Lich's item typing knows, or coins, as floor loot (issue #40)" do
    room.loot = [OpenStruct.new(id: '456', name: 'a flickering torch', noun: 'torch', type: '')]
    expect(reason(final: true)).to be_nil
    room.loot << OpenStruct.new(id: '457', name: 'a blue gem', noun: 'gem', type: 'gem')
    expect(reason(final: true)).to eq(:floor)
    room.loot = [OpenStruct.new(id: '458', name: 'some silver coins', noun: 'coins', type: nil)]
    expect(reason(final: true)).to eq(:floor)
  end
end

RSpec.describe EO::Engine::Actions::Loot do
  it 'accepts the game\'s explicit empty-room response as a terminal answer' do
    expect(described_class::ANSWERS).to match('There is no loot.')
  end
end

RSpec.describe EO::Engine::Behaviors::Loot do
  def npc(id, status: '', type: 'aggressive npc')
    OpenStruct.new(id: id.to_s, name: 'kobold', noun: 'kobold', status: status, type: type)
  end

  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, fxp_pct: 50) }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(type: ''), left: OpenStruct.new(type: '')) }
  let(:room) { OpenStruct.new(id: 1, title: '[Kobold Village]', creatures: [npc(1, status: 'dead')], targets: [], loot: []) }
  let(:world) { OpenStruct.new(me: me, room: room, hands: hands, claim_mine?: true) }
  let(:policy) { EO::Engine::Loot::Policy.new }
  let(:rest_policy) { EO::Engine::Rest::Policy.new(fried: 95, lte_boost: 1, overkill: 2) }
  let(:counters) { EO::Engine::Rest::Counters.new }
  let(:stances) { [] }
  let(:scripts) do
    Class.new do
      attr_reader :started, :killed

      def initialize = (@started = []; @killed = []; @running = []; @paused = [])
      def start(name, args) = (@started << [name, args]; @running << name)
      def running?(name) = @running.include?(name)
      def paused?(name) = @paused.include?(name)
      def kill(name) = (@killed << name; @running.delete(name); @paused.delete(name))
      def finish!(name) = @running.delete(name)
      def pause!(name) = @paused << name
    end.new
  end
  let(:sent) { [] }
  let(:loot) do
    described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, rest_policy: rest_policy,
                        counters: counters, scripts: scripts, stance: ->(s) { stances << s; true })
  end

  before do
    allow(EO::Engine::Actions::Loot).to receive(:new) do |_w, target:|
      sent << (target ? "loot ##{target.id}" : 'loot room')
      instance_double(EO::Engine::Actions::Loot, call: EO::Engine::Actions::Result.new(status: :success))
    end
    allow_any_instance_of(EO::Engine::Actions::LteBoost).to receive(:send_and_match)
      .and_return(EO::Engine::Actions::Result.new(status: :success, line: 'You have deducted 500 experience points from your field experience.'))
    allow_any_instance_of(EO::Engine::Actions::LteBoost).to receive(:sleep)
  end

  after { EO::Engine::Events.reset! }

  it 'loots each corpse once, then the room, and stops wanting control' do
    expect(loot.wants_control?(world)).to be true
    expect(loot.tick(world)).to be_success
    expect(sent).to eq(['loot #1', 'loot room'])
    expect(loot.wants_control?(world)).to be false
    room.creatures << npc(2, status: 'dead')
    expect(loot.wants_control?(world)).to be true
    loot.tick(world)
    expect(sent.last(2)).to eq(['loot #2', 'loot room'])
  end

  it 'retries a corpse its own gate refused, up to three times, and marks it once the game answers' do
    answers = [
      EO::Engine::Actions::Result.new(status: :failed, reason: :muckled),
      EO::Engine::Actions::Result.new(status: :failed, reason: :muckled),
      EO::Engine::Actions::Result.new(status: :success, acted: true)
    ]
    allow(EO::Engine::Actions::Loot).to receive(:new) do |_w, target:|
      sent << (target ? "loot ##{target.id}" : 'loot room')
      instance_double(EO::Engine::Actions::Loot, call: target ? answers.shift : EO::Engine::Actions::Result.new(status: :success))
    end
    3.times do
      expect(loot.wants_control?(world)).to be true
      loot.tick(world)
    end
    expect(sent).to eq(['loot #1', 'loot #1', 'loot #1', 'loot room'])
    expect(loot.wants_control?(world)).to be false
  end

  it 'gives a corpse up after three sends the game refused, and at once on a game answer' do
    refused = EO::Engine::Actions::Result.new(status: :failed, reason: :no_answer)
    allow(EO::Engine::Actions::Loot).to receive(:new) do |_w, target:|
      sent << (target ? "loot ##{target.id}" : 'loot room')
      instance_double(EO::Engine::Actions::Loot, call: refused)
    end
    4.times { loot.tick(world) if loot.wants_control?(world) }
    expect(sent).to eq(['loot #1', 'loot #1', 'loot #1'])

    room.creatures << npc(2, status: 'dead')
    answered = EO::Engine::Actions::Result.new(status: :failed, reason: :no_answer, acted: true)
    allow(EO::Engine::Actions::Loot).to receive(:new) do |_w, target:|
      sent << (target ? "loot ##{target.id}" : 'loot room')
      instance_double(EO::Engine::Actions::Loot, call: answered)
    end
    2.times { loot.tick(world) if loot.wants_control?(world) }
    expect(sent.last(1)).to eq(['loot #2'])
    expect(loot.wants_control?(world)).to be false
  end

  # A gate refusal is one engine tick, a quarter second: three of them fit
  # inside an ordinary stun. They used to spend the corpse's three attempts
  # and mark it looted for the rest of the visit, box and all, where
  # bigshot's bs_put waits the stun out and loots afterwards.
  it 'spends no attempt on a gate refusal, and loots the corpse once the stun passes' do
    muckled = EO::Engine::Actions::Result.new(status: :skipped, reason: :muckled)
    looted = EO::Engine::Actions::Result.new(status: :success, reason: :looted, acted: true)
    answer = muckled
    allow(EO::Engine::Actions::Loot).to receive(:new) do |_w, target:|
      sent << (target ? "loot ##{target.id}" : 'loot room')
      instance_double(EO::Engine::Actions::Loot, call: answer)
    end

    5.times { loot.tick(world) if loot.wants_control?(world) }
    expect(sent).to eq(['loot #1'] * 5)
    expect(loot.wants_control?(world)).to be true

    answer = looted
    loot.tick(world)
    expect(sent).to include('loot #1')
    expect(sent.count { |c| c == 'loot #1' }).to eq(6)
  end

  it 'forgets looted corpses on a new room' do
    loot.wants_control?(world)
    loot.tick(world)
    room.id = 2
    expect(loot.wants_control?(world)).to be true
  end

  it 'drops to defensive once when loot_stance and creatures are still up' do
    policy.stance = true
    room.targets = [npc(5)]
    loot.wants_control?(world)
    loot.tick(world)
    room.creatures << npc(2, status: 'dead')
    loot.wants_control?(world)
    loot.tick(world)
    expect(stances).to eq(['defensive'])
  end

  it 'redeems a boost when fried, else counts an overkill once the boosts are spent' do
    me.fxp_pct = 96
    loot.wants_control?(world)
    loot.tick(world)
    expect(counters.lte_boosts).to eq(1)
    expect(counters.overkill).to eq(0)
    room.creatures << npc(2, status: 'dead')
    loot.wants_control?(world)
    loot.tick(world)
    expect(counters.overkill).to eq(1)
  end

  describe 'the kill accounting (once per corpse)' do
    let(:group_class) do
      Class.new do
        attr_reader :orders

        def initialize(name, looter) = (@name = name; @looter = looter; @orders = [])
        attr_reader :name

        def solo? = false
        def looting_done? = true
        def looter(*) = @looter
        def order(type, payload = nil, room:) = @orders << [type, payload, room]
      end
    end

    it 'counts each corpse handed to a follower looter, and orders the followers once per corpse' do
      me.fxp_pct = 96
      group = group_class.new('Lead', 'Bob')
      leader = described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, rest_policy: rest_policy,
                                   counters: counters, scripts: scripts, group: group, stance: ->(_s) { true })
      room.creatures << npc(2, status: 'dead')
      expect(leader.wants_control?(world)).to be true
      expect(leader.tick(world).reason).to eq(:loot_assigned)
      expect(sent).to be_empty
      expect(counters.lte_boosts).to eq(1)
      expect(counters.overkill).to eq(1)
      expect(group.orders.map(&:first)).to eq(%i[prep_rest loot follower_overkill follower_overkill])
      expect(leader.wants_control?(world)).to be false
    end

    it 'counts a corpse once however many attempts its loot takes' do
      me.fxp_pct = 96
      answers = [
        EO::Engine::Actions::Result.new(status: :failed, reason: :muckled),
        EO::Engine::Actions::Result.new(status: :failed, reason: :muckled),
        EO::Engine::Actions::Result.new(status: :success, acted: true)
      ]
      allow(EO::Engine::Actions::Loot).to receive(:new) do |_w, target:|
        sent << (target ? "loot ##{target.id}" : 'loot room')
        instance_double(EO::Engine::Actions::Loot, call: target ? answers.shift : EO::Engine::Actions::Result.new(status: :success))
      end
      3.times { loot.tick(world) if loot.wants_control?(world) }
      expect(sent).to eq(['loot #1', 'loot #1', 'loot #1', 'loot room'])
      expect(counters.lte_boosts).to eq(1)
      expect(counters.overkill).to eq(0)
    end

    it 'counts nothing on the assigned follower, whose count is the order from the leader' do
      me.fxp_pct = 96
      group = group_class.new('Bob', 'Bob')
      follower = described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, rest_policy: rest_policy,
                                     counters: counters, scripts: scripts, group: group, follower: true, stance: ->(_s) { true })
      follower.assign!
      expect(follower.wants_control?(world)).to be true
      expect(follower.tick(world)).to be_success
      expect(sent).to eq(['loot #1', 'loot room'])
      expect(counters.lte_boosts).to eq(0)
      expect(counters.overkill).to eq(0)
      expect(group.orders).to be_empty
    end
  end

  it 'runs the loot script, waits for it, and marks its corpses looted' do
    policy.script = 'eloot --fast'
    loot.wants_control?(world)
    expect(loot.tick(world).reason).to eq(:script_started)
    expect(scripts.started).to eq([['eloot', '--fast']])
    expect(loot.wants_control?(world)).to be true
    expect(loot.tick(world)).to be_nil
    scripts.finish!('eloot')
    expect(loot.tick(world).reason).to eq(:script_finished)
    expect(loot.wants_control?(world)).to be false
    expect(sent).to be_empty
  end

  context 'when loot temporarily raises encumbrance' do
    let(:rest) { EO::Engine::Behaviors::Rest.new(policy: rest_policy, loot: loot) }

    before do
      policy.script = 'eloot'
      rest_policy.encumbered = 20
      me.encumbrance_pct = 0
      loot.wants_control?(world)
      loot.tick(world)
      me.encumbrance_pct = 30
    end

    it 'lets loot stow the box without committing to a rest' do
      expect(rest.wants_control?(world)).to be false
      expect(loot.tick(world)).to be_nil
      me.encumbrance_pct = 0
      scripts.finish!('eloot')
      loot.tick(world)
      expect(rest.wants_control?(world)).to be false
      expect(rest.resting?).to be false
    end

    it 'rests if the load remains excessive after looting finishes' do
      expect(rest.wants_control?(world)).to be false
      scripts.finish!('eloot')
      loot.tick(world)
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('encumbered.')
    end

    it 'still reports wounds and forced rest while loot is running' do
      rest_policy.wounded = -> { true }
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('wounded.')
      rest.rest!('Box in hand, could not store')
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('Box in hand, could not store')
    end

    it 'omits transient encumbrance from the follower report too' do
      report = -> { EO::Engine::Group.report(world, name: 'Hunter', rest_policy: rest_policy, counters: counters, looting: loot.looting?) }
      expect(report.call.rest_reason).to be_nil
      scripts.finish!('eloot')
      loot.tick(world)
      expect(report.call.rest_reason).to eq('encumbered.')
    end

    it 'lets the existing paused-looter handling force a rest with a stuck box' do
      EO::Engine::Events.on(:loot_stuck) { |event| rest.rest!(event.data[:reason]) }
      scripts.pause!('eloot')
      hands.right = OpenStruct.new(type: 'box')
      expect(rest.wants_control?(world)).to be false
      expect(loot.tick(world).reason).to eq(:box_in_hand)
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq("Box in hand, couldn't store")
    end
  end

  it 'kills a paused loot script and reports a box it could not store' do
    policy.script = 'eloot'
    hands.right = OpenStruct.new(type: 'box')
    stuck = []
    EO::Engine::Events.on(:loot_stuck) { |e| stuck << e.data[:reason] }
    loot.wants_control?(world)
    loot.tick(world)
    scripts.pause!('eloot')
    expect(loot.tick(world).reason).to eq(:box_in_hand)
    expect(scripts.killed).to eq(['eloot'])
    expect(stuck).to eq(["Box in hand, couldn't store"])
  end

  it 'loots the floor on a final loot' do
    room.creatures = []
    room.loot = [OpenStruct.new(noun: 'coins')]
    expect(loot.wants_control?(world)).to be false
    loot.final!
    expect(loot.wants_control?(world)).to be true
    loot.tick(world)
    expect(sent).to eq(['loot room'])
    expect(loot.wants_control?(world)).to be false
  end

  it 'does not retry an unchanged floor observation after a confirmed room loot' do
    policy.final = true
    room.creatures = []
    room.loot = [OpenStruct.new(id: '9', noun: 'wand', name: 'a copper wand', type: 'wand')]

    expect(loot.wants_control?(world)).to be true
    expect(loot.tick(world)).to be_success
    expect(sent).to eq(['loot room'])
    expect(loot.wants_control?(world)).to be false

    room.loot = []
    expect(loot.wants_control?(world)).to be false
    room.loot = [OpenStruct.new(id: '10', noun: 'gem', name: 'a blue gem', type: 'gem')]
    expect(loot.wants_control?(world)).to be true
  end

  it 'ignores scenery in a revisited room, with or without a corpse having been there' do
    policy.final = true
    room.creatures = []
    room.loot = [OpenStruct.new(id: '456', name: 'a flickering torch', noun: 'torch', type: nil)]
    expect(loot.wants_control?(world)).to be false
    room.id = 2
    expect(loot.wants_control?(world)).to be false
    room.id = 1
    expect(loot.wants_control?(world)).to be false
    expect(sent).to eq([])
  end
end
