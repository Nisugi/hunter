# frozen_string_literal: true

# ============================================================================
# watch (Lich's message and combat facts onto the engine's bus)
# ============================================================================

#
# EO::Engine::Watch - the engine's subscription to Lich's parser seam.
# Every game line the behaviors react to is a fact Lich already
# recognises: the message families of Combat::Messages (lich-5 #1586,
# a weapon knocked away, a curse, a trap, an ambusher, a bolt, a bless
# shrugged off, an arrow stuck, a charge counter, a spell mark), the
# UCS facts, and the attack events (an inbound swing, our own rolls).
# Watch subscribes once, names each fact the way the behaviors have
# always heard it, and adds what the moment knows that the line does
# not (our hands and room on a disarm, whether a shrugged item is ours).
#
# The one line Lich cannot know is the profile's own flee text; that is
# the last rule here, on a DownstreamHook installed only when a profile
# has one.
#
#   Watch.install!   # from eohunter, after loading
#
module EO::Engine
  module Watch
    NAME = 'eohunter'
    Rule = Struct.new(:regex, :event, :data, keyword_init: true)

    # Lich's event -> the engine's, when the names differ.
    RENAMED = { item_limit: :too_many_items }.freeze
    # ecleanse's hive trap kinds (set_hooks 1618)
    HIVE_KINDS = { apparatus: :hive_traps_apparatus, ground: :hive_traps_ground }.freeze

    @rules = []
    @mutex = Mutex.new
    @handlers = []

    class << self
      # A rule of the script's own (the profile's flee_message).
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

      # --- Lich's facts, onto the bus -----------------------------------------

      # Every message event, renamed and completed where the behaviors
      # expect more than the line carries.
      def message(type, data)
        event = RENAMED.fetch(type, type)
        data = data.dup
        case type
        when :disarm_seen then data.merge!(disarm_data)
        when :hive_trap
          data[:kind] = HIVE_KINDS.fetch(data[:kind], data[:kind])
          data[:room_id] = room_id
        when :bless_shrugged then data[:mine] = mine?(data[:id], data[:noun])
        end
        Events.emit(event, data)
      end

      # The UCS facts the routines read (bigshot hunt_monitor 2387-2405).
      def ucs(data)
        case data[:kind]
        when :position then Events.emit(:unarmed_tier, tier: data[:tier].to_i, id: data[:id])
        when :tierup then Events.emit(:unarmed_followup, attack: data[:value].to_s, id: data[:id])
        end
      end

      # An attack event: a creature's swing at us is WaitForSwing's
      # :incoming_swing; another player's attack is an :ally_attacked for
      # the afterattack ally casts; each of our own resolutions is a
      # :force_roll (cmd_force 5713 reads the endroll).
      def attack(event)
        if event[:inbound]
          Events.emit(:incoming_swing, target_id: event.dig(:attacker, :id).to_s)
        elsif event[:foreign_caster]
          name = event[:attacker].respond_to?(:[]) ? event[:attacker][:name].to_s : ''
          Events.emit(:ally_attacked, name: name) unless name.empty?
        elsif !event[:foreign_target]
          Array(event[:resolutions]).each do |r|
            Events.emit(:force_roll, roll: r[:result].to_i) if r[:result]
          end
        end
      end

      # The rules of our own, against every line.
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

      # Subscribe to Lich's facts (the tracker on, attack events emitted)
      # and, when the script has rules of its own, a hook for those.
      def install!(name: HOOK_NAME)
        tracker = ::Lich::Gemstone::Combat::Tracker
        tracker.enable! unless tracker.enabled?
        tracker.configure(emit_attacks: true) unless tracker.settings[:emit_attacks]
        @handlers = [
          tracker.on(*::Lich::Gemstone::Combat::Messages.events, name: "#{NAME}:messages") { |type, data| message(type, data) },
          tracker.on(:ucs, name: "#{NAME}:ucs") { |_type, data| ucs(data) },
          tracker.on(:attack, name: "#{NAME}:attack") { |_type, data| attack(data) }
        ]
        return if rules.empty?

        ::DownstreamHook.add(name, hook_proc, persist: false)
        @installed = name
      end

      def uninstall!
        tracker = ::Lich::Gemstone::Combat::Tracker
        @handlers.each { |h| tracker.off(h) }
        @handlers = []
        ::DownstreamHook.remove(@installed) if @installed
        @installed = nil
      end

      def installed? = @handlers.any?

      private

      # The disarm's moment (ecleanse set_hooks: the hands and the room).
      def disarm_data
        world = World.new
        { hands: world.hands, room_id: world.room.id, title: world.room.title }
      rescue StandardError
        { hands: nil, room_id: nil, title: nil }
      end

      def room_id
        World.new.room.id
      rescue StandardError
        nil
      end

      # bigshot hunt_monitor 2359: a shrugged item that is ours (in our
      # inventory or in hand).
      def mine?(id, noun)
        world = World.new
        world.me.inventory_ids.include?(id.to_s) || [world.hands.right, world.hands.left].any? { |h| h.noun.to_s == noun.to_s }
      rescue StandardError
        false
      end
    end
  end
end
