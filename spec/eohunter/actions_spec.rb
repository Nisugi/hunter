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
    allow(action).to receive(:game_put) { |cmd| sent << cmd; queue.concat(replies[cmd].shift || []) }
    allow(action).to receive(:clear_lines) { queue.clear }
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

  describe 'the send ladder' do
    it 'returns the first non-refusal line and leaves it for the confirmation step' do
      replies['attack #1'] << ['You swing a broadsword at a kobold!']
      action = build
      expect(ladder(action, 'attack #1')).to eq('You swing a broadsword at a kobold!')
      expect(action.send(:next_line)).to eq('You swing a broadsword at a kobold!')
    end

    it 'waits out "...wait N" and resends' do
      replies['attack #1'] << ['...wait 2 seconds.'] << ['You swing a broadsword at a kobold!']
      action = build
      expect(ladder(action, 'attack #1')).to start_with('You swing')
      expect(sent).to eq(['attack #1', 'attack #1'])
      expect(slept.sum).to be >= 2
    end

    it 'stands first when the game says so, then resends' do
      replies['attack #1'] << ['You struggle to stand up.'] << ['You swing a broadsword at a kobold!']
      replies['stand'] << ['You stand back up.']
      action = build
      expect(ladder(action, 'attack #1')).to start_with('You swing')
      expect(sent).to eq(['attack #1', 'stand', 'attack #1'])
    end

    it 'waits out a stun before resending' do
      replies['attack #1'] << ['You are still stunned.'] << ['You swing a broadsword at a kobold!']
      action = build
      stunned = [true, true, false]
      allow(me).to receive(:stunned?) { stunned.shift || false }
      expect(ladder(action, 'attack #1')).to start_with('You swing')
      expect(sent).to eq(['attack #1', 'attack #1'])
      expect(slept).to include(0.25)
    end

    it 'resends after a transient refusal, as bigshot does, but only so many times' do
      6.times { replies['attack #1'] << ["You don't seem to be able to move to do that."] }
      action = build
      result = ladder(action, 'attack #1')
      expect(result).to be_a(EO::Engine::Actions::Result)
      expect(result.reason).to eq(:too_many_resends)
      expect(sent.size).to eq(described_class::MAX_RESENDS + 1)
    end

    it 'fails :dead on a refusal when we are dead' do
      replies['attack #1'] << ["You can't do that while dead."]
      me[:dead?] = true
      result = ladder(build, 'attack #1')
      expect(result.reason).to eq(:dead)
    end

    it 'stops when interrupted mid-wait' do
      replies['attack #1'] << ['...wait 5 seconds.']
      stopping = false
      action = build(interrupt: -> { stopping })
      allow(action).to receive(:sleep) { stopping = true }
      result = ladder(action, 'attack #1')
      expect(result.reason).to eq(:interrupted)
      expect(sent).to eq(['attack #1'])
    end

    it 'fails :no_response when the game never answers' do
      action = build
      allow(action).to receive(:clock_now).and_return(Time.at(0), Time.at(described_class::SEND_DEADLINE + 1))
      expect(ladder(action, 'attack #1').reason).to eq(:no_response)
    end

    it 'treats a rummage "can\'t seem to find" as an answer, not a refusal' do
      replies['get my flask'] << ["You rummage through a backpack but can't seem to find a flask."]
      expect(ladder(build, 'get my flask')).to start_with('You rummage')
      expect(sent.size).to eq(1)
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
      allow(action).to receive(:game_put) do |cmd|
        sent << cmd
        queue = ['You swing a broadsword at a kobold!']
        EO::Engine::Events.emit(:swing_resolved, subject: { id: '1' })
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

    it 'waits out hard roundtime but not cast roundtime by default' do
      rt = [true, true, false]
      allow(me).to receive(:in_rt?) { rt.shift || false }
      me[:in_cast_rt?] = true
      action = build
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
      expect(slept.count(0.1)).to eq(2)
    end

    it 'waits out cast roundtime too for a CombatRt action' do
      klass = Class.new(action_class) { include EO::Engine::Actions::CombatRt }
      cast = [true, false]
      allow(me).to receive(:in_cast_rt?) { cast.shift || false }
      action = klass.new(world)
      allow(action).to receive(:sleep) { |s| slept << s }
      allow(action).to receive(:clock_now).and_return(Time.at(0))
      action.perform_block = ->(_a) { EO::Engine::Actions::Result.new(status: :success) }
      expect(action.call).to be_success
      expect(slept).to eq([0.1])
    end
  end
end
