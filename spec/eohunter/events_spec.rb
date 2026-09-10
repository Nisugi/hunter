# frozen_string_literal: true

require_relative 'engine_helper'

RSpec.describe EO::Engine::Events do
  after { described_class.reset! }

  describe '.on / .emit' do
    it 'delivers events to type subscribers' do
      seen = []
      described_class.on(:swing_resolved) { |e| seen << e }
      described_class.emit(:swing_resolved, endroll: 142)
      expect(seen.size).to eq(1)
      expect(seen.first.data[:endroll]).to eq(142)
    end

    it 'does not deliver other types' do
      seen = []
      described_class.on(:swing_resolved) { |e| seen << e }
      described_class.emit(:ward_resolved, margin: 3)
      expect(seen).to be_empty
    end

    it 'delivers everything to :any subscribers' do
      seen = []
      described_class.on(:any) { |e| seen << e.type }
      described_class.emit(:a)
      described_class.emit(:b)
      expect(seen).to eq([:a, :b])
    end

    it 'isolates subscriber errors and reports them' do
      reported = []
      described_class.error_reporter = ->(type, err) { reported << [type, err.message] }
      described_class.on(:tick) { raise 'boom' }
      survivor = []
      described_class.on(:tick) { survivor << 1 }
      expect { described_class.emit(:tick) }.not_to raise_error
      expect(survivor).to eq([1])
      expect(reported).to eq([[:tick, 'boom']])
    ensure
      described_class.error_reporter = nil
    end

    it 'unsubscribes via .off' do
      seen = []
      handler = described_class.on(:tick) { seen << 1 }
      described_class.off(handler)
      described_class.emit(:tick)
      expect(seen).to be_empty
    end
  end

  describe '.await' do
    it 'returns an event emitted from another thread' do
      thread = Thread.new do
        sleep 0.05
        described_class.emit(:swing_resolved, target: '123')
      end
      event = described_class.await(:swing_resolved, timeout: 2)
      thread.join
      expect(event).not_to be_nil
      expect(event.data[:target]).to eq('123')
    end

    it 'applies the matcher block' do
      thread = Thread.new do
        sleep 0.02
        described_class.emit(:swing_resolved, target: 'wrong')
        sleep 0.02
        described_class.emit(:swing_resolved, target: 'right')
      end
      event = described_class.await(:swing_resolved, timeout: 2) { |e| e.data[:target] == 'right' }
      thread.join
      expect(event.data[:target]).to eq('right')
    end

    it 'returns nil on timeout and cleans up its waiter' do
      expect(described_class.await(:never, timeout: 0.1)).to be_nil
      expect(described_class.instance_variable_get(:@waiters)).to be_empty
    end
  end
end
