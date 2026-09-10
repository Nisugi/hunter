# frozen_string_literal: true

# ============================================================================
# events (from forge events.rb)
# ============================================================================

#
# EO::Engine::Events - in-process pub/sub event bus with blocking await.
#
# The spine of the framework: parsers/hooks emit, actions await, the
# logger/recorder subscribe. Thread-safe: emissions typically arrive from
# Lich's downstream hook thread while awaits block the engine thread.
#
# Depends on nothing (pure Ruby) so it is fully spec-testable.
#
module EO::Engine
  module Events
    Event = Struct.new(:type, :data, :at, keyword_init: true)

    @mutex = Mutex.new
    @subscribers = Hash.new { |h, k| h[k] = [] } # type => [callable, ...]
    @any_subscribers = []
    @waiters = [] # [{types:, matcher:, queue:}]

    class << self
      # Subscribe to one or more event types (or :any). Returns the handler
      # (keep it if you want to unsubscribe).
      def on(*types, &block)
        raise ArgumentError, 'block required' unless block

        @mutex.synchronize do
          if types.empty? || types == [:any]
            @any_subscribers << block
          else
            types.each { |t| @subscribers[t] << block }
          end
        end
        block
      end

      def off(handler)
        @mutex.synchronize do
          @any_subscribers.delete(handler)
          @subscribers.each_value { |list| list.delete(handler) }
        end
        nil
      end

      # Emit an event. Subscribers run inline on the emitting thread; a
      # subscriber that raises is reported (if a reporter is set) but never
      # breaks other subscribers or the emitter.
      def emit(type, data = {})
        event = Event.new(type: type, data: data, at: Time.now)
        handlers, waiters = @mutex.synchronize do
          [@subscribers[type].dup + @any_subscribers.dup, @waiters.dup]
        end
        handlers.each do |h|
          begin
            h.call(event)
          rescue StandardError => e
            report_subscriber_error(type, e)
          end
        end
        waiters.each do |w|
          next unless w[:types].include?(type)
          next if w[:matcher] && !safe_match?(w[:matcher], event)

          w[:queue] << event
        end
        event
      end

      # Block until an event of one of +types+ arrives (optionally passing
      # +matcher+, a callable given the event). Returns the Event, or nil on
      # timeout. This is what verified actions build on.
      def await(*types, timeout:, &matcher)
        queue = Queue.new
        waiter = { types: types, matcher: matcher, queue: queue }
        @mutex.synchronize { @waiters << waiter }
        begin
          deadline = Time.now + timeout
          loop do
            remaining = deadline - Time.now
            return nil if remaining <= 0

            begin
              return queue.pop(true)
            rescue ThreadError
              sleep([remaining, 0.05].min)
            end
          end
        ensure
          @mutex.synchronize { @waiters.delete(waiter) }
        end
      end

      # Register a watch for +types+ BEFORE running the block (typically a
      # command send), then wait for a matching event. Closes the race where
      # the event arrives between send and a subsequent await. Returns the
      # Event or nil on timeout.
      def during(types, timeout:, matcher: nil)
        queue = Queue.new
        waiter = { types: Array(types), matcher: matcher, queue: queue }
        @mutex.synchronize { @waiters << waiter }
        begin
          yield
          deadline = Time.now + timeout
          loop do
            remaining = deadline - Time.now
            return nil if remaining <= 0

            begin
              return queue.pop(true)
            rescue ThreadError
              sleep([remaining, 0.05].min)
            end
          end
        ensure
          @mutex.synchronize { @waiters.delete(waiter) }
        end
      end

      # Errors raised by subscribers are handed to this callable (e.g. the
      # logger); defaults to silent to keep the bus dependency-free.
      attr_accessor :error_reporter

      def reset!
        @mutex.synchronize do
          @subscribers.clear
          @any_subscribers.clear
          @waiters.clear
        end
      end

      private

      def safe_match?(matcher, event)
        matcher.call(event)
      rescue StandardError
        false
      end

      def report_subscriber_error(type, error)
        error_reporter&.call(type, error)
      end
    end
  end
end
