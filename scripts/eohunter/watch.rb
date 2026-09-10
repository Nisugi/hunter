# frozen_string_literal: true

# ============================================================================
# watch (the engine's one DownstreamHook: lines that matter, as events)
# ============================================================================

#
# EO::Engine::Watch - bigshot's hunt_monitor as a rule table. One
# DownstreamHook, installed by the RUNNING script (a library script exits
# as soon as it loads, and Lich removes a dead script's hooks), that passes
# every line through untouched and emits an event when a rule matches.
# Combat facts still come from Combat::Observers; this is for the handful
# of non-combat lines the behaviors need.
#
#   Watch.on(/^You bolt/i, :bolted)
#   Watch.on(/(?<noun>\w+) leaps from hiding to attack/, :ambusher) { |m| { noun: m[:noun] } }
#   Watch.install!   # from eohunter, after loading
#
module EO::Engine
  module Watch
    Rule = Struct.new(:regex, :event, :data, keyword_init: true)

    @rules = []
    @mutex = Mutex.new

    class << self
      # @param regex [Regexp] matched against the raw server line
      # @param event [Symbol] emitted on the bus with the match's data
      # @yield [MatchData] optional, returns the event data
      def on(regex, event, &data)
        rule = Rule.new(regex: regex, event: event, data: data)
        @mutex.synchronize { @rules << rule }
        rule
      end

      def off(rule)
        @mutex.synchronize { @rules.delete(rule) }
      end

      def clear!
        @mutex.synchronize { @rules.clear }
      end

      def rules = @mutex.synchronize { @rules.dup }

      # Emit for every rule the line matches. Never raises, never changes
      # the line.
      def process(line)
        rules.each do |rule|
          m = rule.regex.match(line)
          next unless m

          data = rule.data ? rule.data.call(m) : {}
          Events.emit(rule.event, (data || {}).merge(raw: line))
        rescue StandardError => e
          Events.emit(:watch_error, event: rule.event, error: "#{e.class}: #{e.message}")
        end
        nil
      end

      def hook_proc
        proc do |line|
          process(line) if line.is_a?(String)
          line
        end
      end

      # Install from the running script. +persist+ false: the hook goes
      # away with that script.
      def install!(name: HOOK_NAME)
        ::DownstreamHook.add(name, hook_proc, persist: false)
        @installed = name
      end

      def uninstall!
        ::DownstreamHook.remove(@installed) if @installed
        @installed = nil
      end

      def installed? = !@installed.nil?
    end
  end
end
