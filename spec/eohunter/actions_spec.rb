# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

# Actions::Base: bigshot's send ladder with bounds, and the three
# confirmation shapes. The game is a scripted queue: each send pushes the
# replies scripted for that command.
RSpec.describe EO::Engine::Actions::Base do
  let(:me) do
    OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false)
  end
  let(:world) { OpenStruct.new(me: me) }
  let(:replies) { Hash.new { |h, k| h[k] = [] } }
  let(:sent) { [] }
  let(:slept) { [] }

  # A concrete action whose perform is chosen per example.
  let(:action_class) do
    Class.new(described_class) do
      attr_accessor :perform_block

      def preconditions = :ok

      def perform = perform_block.call(self)
    end
  end

  def build(interrupt: nil, **opts)
    action = action_class.new(world, interrupt: interrupt, **opts)
    queue = []
    allow(action).to receive(:game_send) { |cmd| sent << cmd; queue.concat(replies[cmd].shift || []); queue.first || :no_response }
    allow(action).to receive(:next_line) { queue.shift }
    allow(action).to receive(:unread_line) { |line| queue.unshift(line) }
    allow(action).to receive(:sleep) { |s| slept << s }
    allow(action).to receive(:live_target_ids).and_return(nil)
    # a clock that advances a little on every read, so deadlines can pass
    tick = 0.0
    allow(action).to receive(:clock_now) { tick += 0.01; Time.at(tick) }
    action
  end

  def ladder(action, command)
    action.send(:send_through_ladder, command)
  end

  # The refusal ladder itself is fput's (lich-5 #1587, specced there);
  # the engine's part is naming its answers.
  describe 'the send ladder' do
    it 'returns the answer line and leaves it for the confirmation step' do
      replies['attack #1'] << ['You swing a broadsword at a kobold!']
      action = build
      expect(ladder(action, 'attack #1')).to eq('You swing a broadsword at a kobold!')
      expect(action.send(:next_line)).to eq('You swing a broadsword at a kobold!')
    end

    it 'asks fput for the bounds: the cap, the deadline, the interrupt, the transient resend, named failures' do
      stopping = -> { false }
      action = action_class.new(world, interrupt: stopping)
      expect(action).to receive(:fput).with('attack #1', max_resends: described_class::MAX_RESENDS, timeout: described_class::SEND_DEADLINE,
                                                         interrupt: stopping, resend_transient: true, failures: :symbol).and_return('You swing')
      expect(ladder(action, 'attack #1')).to eq('You swing')
    end

    it 'turns each of fput\'s failures into a failed Result' do
      %i[too_many_resends interrupted dead no_response].each do |reason|
        action = build
        allow(action).to receive(:game_send).and_return(reason)
        result = ladder(action, 'attack #1')
        expect(result).to be_a(EO::Engine::Actions::Result)
        expect(result.reason).to eq(reason)
      end
    end

    it 'treats no answer at all as :no_response' do
      action = build
      allow(action).to receive(:game_send).and_return(nil)
      expect(ladder(action, 'attack #1').reason).to eq(:no_response)
    end
  end

  describe '#send_and_match' do
    it 'succeeds on the first line matching the result regex' do
      replies['cman feint #1'] << ['You feint to the left of a kobold!', 'Roundtime: 3 sec.']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'cman feint #1', /You feint|Roundtime/) }
      result = action.call
      expect(result).to be_success
      expect(result.line).to eq('You feint to the left of a kobold!')
    end

    it 'times out with :no_confirmation when nothing matches' do
      replies['cman feint #1'] << ['Something unexpected.']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'cman feint #1', /You feint/, timeout: 0.05) }
      result = action.call
      expect(result.status).to eq(:timeout)
      expect(result.reason).to eq(:no_confirmation)
    end
  end

  describe '#send_and_observe' do
    it 'succeeds once the world shows the change' do
      replies['stand'] << ['You stand back up.']
      standing = [false, false, true]
      action = build
      action.perform_block = ->(a) { a.send(:send_and_observe, 'stand') { standing.shift } }
      expect(action.call).to be_success
    end

    it 'times out with :state_unchanged' do
      replies['stand'] << ['You are already standing.']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_observe, 'stand', timeout: 0.05) { false } }
      expect(action.call.reason).to eq(:state_unchanged)
    end
  end

  describe '#send_and_await' do
    after { EO::Engine::Events.reset! }

    it 'confirms on a bus event emitted after the send' do
      action = build
      queue = nil
      allow(action).to receive(:next_line) { queue&.shift }
      allow(action).to receive(:game_send) do |cmd|
        sent << cmd
        queue = ['You swing a broadsword at a kobold!']
        EO::Engine::Events.emit(:swing_resolved, subject: { id: '1' })
        queue.first
      end
      action.perform_block = ->(a) { a.send(:send_and_await, 'attack #1', :swing_resolved, timeout: 0.2) }
      result = action.call
      expect(result).to be_success
      expect(result.event.type).to eq(:swing_resolved)
    end

    it 'returns the ladder failure instead of waiting on the bus' do
      replies['attack #1'] << ["You can't do that while dead."]
      me[:dead?] = true
      action = build
      action.perform_block = ->(a) { a.send(:send_and_await, 'attack #1', :swing_resolved, timeout: 0.2) }
      expect(action.call.reason).to eq(:dead)
    end
  end

  describe 'the engine interrupt' do
    after { described_class.interrupt = nil }

    # 46 call sites build actions, each forwarding an @interrupt it was
    # handed; nothing supplied a root one, so every interrupted? guard in
    # the engine was inert and stop! could not shorten a wait in flight.
    it 'is inherited by an action that was not given its own' do
      described_class.interrupt = -> { true }
      action = build
      action.perform_block = ->(_a) { raise 'must not perform: interrupted' }
      expect(action.call).to have_attributes(reason: :interrupted)
    end

    it 'yields to an interrupt passed explicitly' do
      described_class.interrupt = -> { true }
      action = build(interrupt: -> { false })
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
    end
  end

  describe '#call' do
    it 'fails on a precondition without sending' do
      action = build
      allow(action).to receive(:preconditions).and_return(:muckled)
      expect(action.call.reason).to eq(:muckled)
      expect(sent).to be_empty
    end

    it 'fails :target_gone after roundtime when the target left the live list' do
      action = build(target: OpenStruct.new(id: '7'))
      allow(action).to receive(:live_target_ids).and_return(['8'])
      action.perform_block = ->(_a) { raise 'must not perform' }
      expect(action.call.reason).to eq(:target_gone)
    end

    it 'lets a collective word target through the live check, since it names no creature' do
      action = build(target: 'all')
      allow(action).to receive(:live_target_ids).and_return(['8'])
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
    end

    it 'still checks a creature given by its bare id' do
      action = build(target: '7')
      allow(action).to receive(:live_target_ids).and_return(['8'])
      action.perform_block = ->(_a) { raise 'must not perform' }
      expect(action.call.reason).to eq(:target_gone)
    end

    it 'waits out hard roundtime but not cast roundtime by default' do
      action = build
      waited = []
      allow(action).to receive(:game_wait_rt) { |kind| waited << kind }
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
      expect(waited).to eq([:hard])
    end

    it 'waits out cast roundtime too for a CombatRt action' do
      klass = Class.new(action_class) { include EO::Engine::Actions::CombatRt }
      action = klass.new(world)
      waited = []
      allow(action).to receive(:game_wait_rt) { |kind| waited << kind }
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
      expect(waited).to eq(%i[hard cast])
    end

    it 'asks Lich to wait, capped and interruptible' do
      stopping = -> { false }
      action = action_class.new(world, interrupt: stopping)
      expect(action).to receive(:waitrt?).with(interrupt: stopping, cap: described_class::RT_SETTLE_CAP).and_return(false)
      action.send(:game_wait_rt, :hard)
      expect(action).to receive(:waitcastrt?).with(interrupt: stopping, cap: described_class::RT_SETTLE_CAP).and_return(false)
      action.send(:game_wait_rt, :cast)
    end
  end

  # The engine's fire budget counts commands the game received, and the
  # send seam is the only thing that knows. So Base stamps `acted` on the
  # way out of `call`, and nothing else may.
  describe 'the acted stamp' do
    it 'stamps a result whose perform sent a command, whatever the game answered' do
      replies['attack #1'] << ['You swing a broadsword at a kobold!']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'attack #1', /swing/) }
      expect(action.call).to be_acted

      action = build
      allow(action).to receive(:game_send).and_return(:too_many_resends)
      action.perform_block = ->(a) { a.send(:send_and_match, 'attack #1', /swing/) }
      result = action.call
      expect(result).to be_failed
      expect(result).to be_acted
    end

    it 'does not stamp a perform that returned without sending, or a gate that refused before perform' do
      action = build
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success, reason: :already_hidden) }
      expect(action.call).not_to be_acted
      expect(sent).to be_empty

      refused = action_class.new(world)
      allow(refused).to receive(:preconditions).and_return(:muckled)
      expect(refused.call).not_to be_acted
    end

    it 'starts each call clean, so one instance reused after a send does not carry the stamp' do
      replies['attack #1'] << ['You swing a broadsword at a kobold!']
      action = build
      action.perform_block = ->(a) { a.send(:send_and_match, 'attack #1', /swing/) }
      expect(action.call).to be_acted
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).not_to be_acted
    end

    it 'is set nowhere but Base: no behavior or action writes acted by hand' do
      root = File.expand_path('../../scripts', __dir__)
      offenders = Dir[File.join(root, '**', '*.{rb,lic}')].select do |path|
        next false if path.end_with?('eohunter/actions.rb')

        File.read(path) =~ /\bacted:\s|\.acted\s*=/
      end
      expect(offenders).to eq([])
      base = File.read(File.join(root, 'eohunter', 'actions.rb'))
      expect(base.scan(/\.acted\s*=/).size).to eq(1)
    end
  end
end
