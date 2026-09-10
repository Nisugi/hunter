# frozen_string_literal: true

# ============================================================================
# objective (ebounty's cycle for the hunting bounties, inside the engine)
# ============================================================================

#
# ebounty 1.11.2 is a loop over Lich's Bounty task (Task.bounty_check
# 2305): nothing assigned, ask the taskmaster (2507); an assignment,
# ask the guard or the furrier for the details (2661, 2460); a task,
# switch to the creature's bigshot profile (703) and run bigshot bounty
# until its bounty_eval says done (2234, 2078); done, rest, turn in,
# heal, sell, bank (2809, 3576); repeat. The engine's Objective::Bounty
# is that cycle as a behavior at priority 18, above Rest: the town
# phases are its own trips and actions, one per tick; the hunt is the
# engine's other behaviors on the creature's profile, which the script
# swaps in through a hook; when the task is done the objective waits
# for Rest to bring us home, then does the town. The bounty types that
# are hunts (cull, dangerous, bandit, skin) run here; gem, herb, heirloom,
# escort and rescue are refused or removed and stay ebounty's. Rules and
# ebounty line references in hunting-engine-plan.md, "Bounty objective".
#
module EO::Engine
  module Objective
    module Bounty
      # ebounty's crosswalk (887): Lich's task type to the setup's name.
      CROSSWALK = {
        bandit_assignment: 'kill_bandits', bandit: 'kill_bandits', creature_assignment: 'kill_creatures',
        cull: 'culling', dangerous: 'boss_culling', dangerous_spawned: 'boss_culling', escort: 'escort',
        gem_assignment: 'gem_collecting', gem: 'gem_collecting', heirloom_assignment: 'heirloom_both', heirloom: 'heirloom_both',
        herb_assignment: 'foraging', herb: 'foraging', rescue_assignment: 'rescue', rescue: 'rescue',
        skin_assignment: 'skinning', skin: 'skinning'
      }.freeze

      # What the engine hunts; the rest are ebounty's.
      HUNTED = %i[bandit cull dangerous dangerous_spawned skin].freeze
      HUNT_ASSIGNMENTS = %i[bandit_assignment creature_assignment skin_assignment].freeze

      # ebounty 1049: the bounty town's room by name.
      TOWNS = {
        'Icemule Trace' => 'u4042150', 'Kharam-Dzu' => 'u3001025', "Kraken's Fall" => 'u7118221', 'Mist Harbor' => 'u3201029',
        "River's Rest" => 'u2101008', 'Solhaven' => 'u4209030', 'Vornavis' => 'u4209030', "Ta'Illistim" => 'u13100042',
        "Ta'Vaalor" => 'u14100047', "Wehnimer's Landing" => 'u7120', 'Zul Logoth' => 'u13006016', 'Cold River' => 'u7503205',
        'Contempt' => 'u7150608'
      }.freeze

      # The guard's answers (ebounty 1020).
      GUARD_ANSWERS = Regexp.union(
        /suppress bandit activity|bandits you encounter/,
        /particularly dangerous|cull their numbers|(?!.*bandit)suppress .* activity/,
        /SEARCH the area|do a thorough SEARCH/,
        /LOOT the item from its corpse/,
        /I don't have any tasks for you right now/,
        /Try bugging me later/,
        /Ah, so you have returned/,
        /You have completed your task/
      )
      GUARD_NO_TASK = /I don't have any tasks for you right now|Try bugging me later|Who are you trying to ask\?/
      GUARD_NAMES = /(?:guard|sergeant|guardsman|sentry|tavernkeeper|alchemist|Malovor)/i
      # ebounty 921
      FURRIER_NAMES = /Bramblefist|Delosa|dwarven clerk|furrier|patchwork flesh merchant/i
      BANDIT_NOUNS = '(?:thief|rogue|bandit|mugger|outlaw|highwayman|marauder|brigand|thug|robber)'
      MAX_CRAWL_ROOMS = 100 # ebounty 2303
      ASK_ATTEMPTS = 5      # ebounty 2463, 2510

      # ebounty.yaml, the keys the hunting cycle reads. Profiles are the
      # per-letter creature lists (names_a, profile_a, kill_a; 703-729).
      Policy = Struct.new(:types, :default_profile, :bandits_profile, :kill_bandits, :profiles, :creature_exclude, :location_exclude,
                          :exp_pause, :keep_hunting, :once_and_done, :new_bounty_on_exit, :selling_script, :healing_script, :skip_healing,
                          :extra_skin, :use_vouchers, :boost_type, :ranger_track, :wander_wait, :bad_rooms, :keep_silver, :basic,
                          keyword_init: true) do
        def initialize(types: [], default_profile: nil, bandits_profile: nil, kill_bandits: false, profiles: {}, creature_exclude: [],
                       location_exclude: [], exp_pause: false, keep_hunting: false, once_and_done: false, new_bounty_on_exit: false,
                       selling_script: 'eloot', healing_script: 'eherbs', skip_healing: false, extra_skin: 0, use_vouchers: false,
                       boost_type: nil, ranger_track: false, wander_wait: 0.5, bad_rooms: [], keep_silver: 0, basic: false) = super

        # @param uid_ids [#call] (uid) -> [lich ids], for the bad rooms
        def self.load(path, uid_ids: nil)
          require 'yaml'
          raw = File.exist?(path) ? (YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}) : {}
          from(raw, uid_ids: uid_ids)
        end

        def self.from(raw, uid_ids: nil)
          s = raw.to_h { |k, v| [k.to_s, v] }
          profiles = ('a'..'j').to_h { |l| [l, { names: s["names_#{l}"].to_s, profile: s["profile_#{l}"].to_s, kill: s["kill_#{l}"] ? true : false }] }
          bad = (1..12).flat_map { |i| s["bad_room#{i}"].to_s.split(/,\s*/) }.map { |r| room_id(r, uid_ids) }.compact
          new(types: Array(s['bounty_types']).map(&:to_s), default_profile: blank(s['default_profile']), bandits_profile: blank(s['bandits_profile']),
              kill_bandits: s['kill_bandits'] ? true : false, profiles: profiles,
              creature_exclude: Array(s['creature_exclude']).map { |c| c.to_s.downcase }, location_exclude: Array(s['location_exclude']).map { |c| c.to_s.downcase },
              exp_pause: s['exp_pause'] ? true : false, keep_hunting: s['keep_hunting'] ? true : false, once_and_done: s['once_and_done'] ? true : false,
              new_bounty_on_exit: s['new_bounty_on_exit'] ? true : false, selling_script: blank(s['selling_script']) || 'eloot',
              healing_script: blank(s['healing_script']) || 'eherbs', skip_healing: s['skip_healing'] ? true : false, extra_skin: s['extra_skin'].to_i,
              use_vouchers: s['use_vouchers'] ? true : false, boost_type: blank(s['boost_type']), ranger_track: s['ranger_track'] ? true : false,
              wander_wait: (s['wander_wait'] || 0.5).to_f, bad_rooms: bad, basic: s['basic'] ? true : false)
        end

        def self.blank(value) = value.to_s.strip.empty? ? nil : value.to_s

        def self.room_id(value, uid_ids)
          v = value.to_s.strip
          return v.to_i if v =~ /\A\d+\z/
          return uid_ids&.call(v[1..].to_i)&.first if v =~ /\Au\d+\z/i

          nil
        end

        # switch_profile (703-729): the letter whose names match, else the
        # bandits profile, else nil (keep_hunting hunts the default).
        #
        # @return [Array(String, Boolean), nil] the profile name and
        #   whether only the bounty creature is hunted
        def profile_for(creature)
          if creature == 'bandits'
            return nil if bandits_profile.nil?

            return [bandits_profile, kill_bandits]
          end
          letter = profiles.keys.find { |l| !profiles[l][:names].empty? && profiles[l][:names] =~ /#{Regexp.escape(creature.to_s)}/i }
          return nil if letter.nil? || profiles[letter][:profile].empty?

          [profiles[letter][:profile], profiles[letter][:kill]]
        end

        # check_removal 2426: a type the setup did not ask for.
        def wanted?(type)
          name = CROSSWALK[type]
          return true if name.nil?
          return types.grep(/culling/).any? if name == 'kill_creatures'
          return types.include?('heirloom_loot') || types.include?('heirloom_search') if name == 'heirloom_both'

          types.include?(name)
        end
      end

      module Predicates
        module_function

        # Where the cycle is for a task (bounty_check 2317): :none, :done
        # (turn in), :failed, :guard (ask a guard), :furrier (ask the
        # furrier), :hunt, or :other (a type the engine does not run).
        def stage(task)
          type = task&.type
          return :none if type.nil? || type == :none
          return :done if type == :taskmaster
          return :failed if type == :failed
          return :guard if %i[guard bandit_assignment creature_assignment].include?(type)
          return :furrier if type == :skin_assignment
          return :hunt if HUNTED.include?(type)

          :other
        end

        # check_removal 2408-2427 minus the gem and herb lists.
        def remove?(task, policy)
          return false if task.nil? || task.none?

          req = task.requirements || {}
          return true if policy.creature_exclude.any? && req[:creature] && policy.creature_exclude.any? { |c| req[:creature].to_s.downcase =~ /#{Regexp.escape(c)}/ }
          return true if policy.location_exclude.any? && req[:area] && policy.location_exclude.any? { |c| req[:area].to_s.downcase =~ /#{Regexp.escape(c)}/ }

          !policy.wanted?(task.type)
        end

        # skin_bounty 3546-3563: skins in the containers against the count
        # (plus extra_skin); bundles are not measured.
        def skins_have(world, skin)
          name = skin.to_s.strip.downcase.gsub(/s$/, '').gsub(/teeth/, 'tooth').gsub(/hooves?/, 'hoof')
          return 0 if name.empty?

          world.container_item_names.count { |n| n.downcase =~ /#{Regexp.escape(name)}/ }
        end

        def skins_needed(task, policy) = task.requirements[:number].to_i + policy.extra_skin.to_i

        # The report's bounty state (the split plan's 3.1).
        def state(world, policy, task = world.bounty_task)
          case stage(task)
          when :none then :none
          when :done, :guard, :furrier then :complete
          when :failed then :failed
          when :hunt
            task.type == :skin && skins_have(world, task.requirements[:skin]) >= skins_needed(task, policy) ? :complete : :hunting
          else :none
          end
        end

        # The bandit area (find_location 2734): the location's rooms minus
        # the bad ones, the nearest as the start, capped to a contiguous
        # region (limit_crawl_area 2779), the neighbours outside as
        # boundaries.
        def location_area(world, name, bad_rooms: [])
          rooms = world.rooms_in_location(name) - bad_rooms
          return nil if rooms.empty?

          start = world.nearest_reachable(rooms)
          return nil if start.nil?

          rooms = crawl(world, start, rooms) if rooms.size > MAX_CRAWL_ROOMS
          boundaries = rooms.flat_map { |id| world.exits_from(id).keys.reject { |n| rooms.include?(n) } }.uniq
          { start: start, rooms: rooms, boundaries: boundaries }
        end

        def crawl(world, start, rooms, max = MAX_CRAWL_ROOMS)
          selected = []
          queue = [start.to_i]
          until queue.empty? || selected.size >= max
            current = queue.shift
            next if selected.include?(current)

            selected << current
            world.exits_from(current).each_key do |n|
              next if selected.include?(n) || queue.include?(n) || !rooms.include?(n)

              queue << n
            end
          end
          selected
        end

        # guard_list 2641: the advguard rooms whose nearest town is the
        # task's town and that the town can reach.
        def guard_rooms(world, town_name)
          town_uid = TOWNS[town_name.to_s]
          return [] if town_uid.nil?

          town = world.uid_ids(town_uid[1..].to_i).first
          return [] if town.nil?

          world.rooms_tagged(/advguard/).select { |id| world.nearest_by_tag_from(id, 'town') == town && world.routable?(town, id) }
        end
      end
    end
  end

  module Actions
    # ask_taskmaster (2507): ASK <taskmaster> ABOUT BOUNTY | REMOVAL |
    # EXPEDITING at the guild, confirmed by the bounty text changing
    # within three seconds (bounty_change 309); removal asks twice.
    class AskTaskmaster < Base
      KINDS = { get: 'bounty', turn_in: 'bounty', failure: 'bounty', remove: 'removal', expedite: 'expediting' }.freeze
      SAILORS_GRIEF = [7150601, 7150602, 7150603, 7150604, 7150605, 7150606, 7150607, 7150608, 7150609, 7150610,
                       7150611, 7150612, 7150613, 7150614, 7150615, 7150616, 7150617, 7150621, 7150622].freeze

      def initialize(world, kind:, boost_type: nil, clock: Time, **opts)
        super(world, **opts)
        @kind = kind
        @boost_type = boost_type
        @clock = clock
      end

      def preconditions
        return :dead if me.dead?
        return :not_at_guild unless @world.room.tags.include?('advguild') || SAILORS_GRIEF.include?(@world.room.uid.to_i)

        :ok
      end

      # find_taskmaster 2592-2596
      def taskmaster
        uid = @world.room.uid.to_i
        return 'Halfwhistle' if uid == 7503207
        return 'Seldit' if SAILORS_GRIEF.include?(uid)

        'Taskmaster'
      end

      def perform
        before = @world.bounty_text
        topic = KINDS.fetch(@kind)
        topic = "#{topic} #{@boost_type}" if @kind == :get && @boost_type && me.effect_active?('Bounty Boost')
        (@kind == :remove ? 2 : 1).times do
          line = send_through_ladder("ask #{taskmaster} about #{topic}")
          return line if line.is_a?(Result)
          return Result.new(status: :success, reason: :already_assigned, line: line) if line =~ /You have already been assigned a task/
          return Result.new(status: :success, reason: :ready, line: line) if line =~ /I'm ready to assign you a new task/ && @kind == :expedite
          return Result.new(status: :failed, reason: :no_taskmaster, line: line) if line =~ /Who are you trying to ask/

          settle_rt
        end
        deadline = @clock.now + 3
        until @clock.now > deadline
          return Result.new(status: :success, reason: :changed) if @world.bounty_text != before

          sleep 0.2
        end
        Result.new(status: :timeout, reason: :no_change)
      end
    end

    # ask_guard 2717: ASK <guard> ABOUT BOUNTY to each guard-looking
    # thing here; River's Rest has a purser.
    class AskGuard < Base
      def initialize(world, clock: Time, **opts)
        super(world, **opts)
        @clock = clock
      end

      def guards
        return ['purser'] if @world.room_location(@world.room.id).to_s =~ /the town of River's Rest/

        @world.room.npcs_and_desc.select { |o| o.name.to_s =~ EO::Engine::Objective::Bounty::GUARD_NAMES }.map { |o| o.noun.to_s }
      end

      def preconditions
        return :dead if me.dead?
        return :no_guard if guards.empty?

        :ok
      end

      def perform
        before = @world.bounty_text
        guards.each do |guard|
          result = send_and_match("ask #{guard} about bounty", EO::Engine::Objective::Bounty::GUARD_ANSWERS, timeout: 3)
          next if result.line.to_s =~ EO::Engine::Objective::Bounty::GUARD_NO_TASK
          return result unless result.success?

          deadline = @clock.now + 3
          until @clock.now > deadline
            return Result.new(status: :success, reason: :changed, line: result.line) if @world.bounty_text != before

            sleep 0.2
          end
          return Result.new(status: :success, reason: :answered, line: result.line)
        end
        Result.new(status: :failed, reason: :no_task_here)
      end
    end

    # ask_assignment 2486-2494: ASK #<npc> ABOUT BOUNTY, confirmed by the
    # bounty text changing.
    class AskNpc < Base
      def initialize(world, names:, clock: Time, **opts)
        super(world, **opts)
        @names = names
        @clock = clock
      end

      def npc = @world.room.npcs_and_desc.find { |o| o.name.to_s =~ @names }

      def preconditions
        return :dead if me.dead?
        return :no_npc if npc.nil?

        :ok
      end

      def perform
        before = @world.bounty_text
        line = send_through_ladder("ask ##{npc.id} about bounty")
        return line if line.is_a?(Result)

        deadline = @clock.now + 3
        until @clock.now > deadline
          return Result.new(status: :success, reason: :changed) if @world.bounty_text != before

          sleep 0.2
        end
        Result.new(status: :timeout, reason: :no_change)
      end
    end

    # silver_deposit 812-832 at the bank.
    class Deposit < Base
      ANSWER = /You deposit|You hand|deposit|The teller|You don't have that much|What/i

      def initialize(world, amount:, **opts)
        super(world, **opts)
        @amount = amount.to_i
      end

      def preconditions
        return :dead if me.dead?
        return :nothing unless @amount.positive?

        :ok
      end

      def perform = send_and_match("deposit #{@amount}", ANSWER, timeout: 5)
    end
  end

  module Behaviors
    # The bounty cycle, one step per tick, above Rest. Between the town
    # phases it holds no control: the hunt is everyone else's, on the
    # creature's profile the hooks swapped in.
    class Bounty < Behavior
      # @param policy [Objective::Bounty::Policy]
      # @param hooks [Hash] :switch (profile, creature:, only:, bandits:, area:, track:) -> void,
      #   :rest -> the current Rest, :stop (reason) -> void
      # @param group [Group::Leader, nil]
      def initialize(policy:, hooks:, group: nil, travel: nil, scripts: nil, clock: Time)
        super()
        @policy = policy
        @hooks = hooks
        @group = group
        @travel = travel || EO::Engine::Travel.default
        @scripts = scripts || EO::Engine::Behaviors::Rest::LichScripts
        @clock = clock
        @trip = nil
        @phase = :check
        @attempts = 0
        @task = nil
        @hunting = false
        @home = nil
        @waiting = nil
        @noticed_at = nil
      end

      attr_reader :phase, :task

      def priority = 18

      def name = 'bounty'

      def cancel! = EO::Engine::Travel.cancel(self)
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      # The report's state for a group member.
      def state(world) = EO::Engine::Objective::Bounty::Predicates.state(world, @policy)

      def wants_control?(world)
        return true unless @phase == :hunt

        # the hunt: ours again when the task is done and Rest has us home,
        # or the task went away, or the group is lost
        done = hunt_done?(world)
        if @group && !@group.solo?
          case @group.verdict(done ? :complete : :hunting)
          when :member_lost
            @group.end_hunt(:member_lost)
            @hooks[:stop].call(:member_lost)
            return false
          when :bounty_complete then done = true
          end
        end
        rest = @hooks[:rest].call
        if done && !@rested
          # set_eval 2087: exp_pause rests at once; a bandit bounty always
          # (2095); otherwise the hunt goes on until a normal rest
          if (@policy.exp_pause || @bandits) && rest.respond_to?(:rest!) && !rest.resting?
            rest.rest!('bounty complete.')
          end
          @rested = true
        end
        return true if done && rest.respond_to?(:phase) && rest.phase == :resting
        return true if EO::Engine::Objective::Bounty::Predicates.stage(world.bounty_task) == :none && !@keep_hunting
        return true if @keep_hunting && world.cooldown_minutes_left('Next Bounty') <= 0 && rest.respond_to?(:phase) && rest.phase == :resting

        false
      end

      def tick(world)
        case @phase
        when :check then check(world)
        when :to_guild then go(world, 'advguild', next_phase: :ask)
        when :ask then ask(world)
        when :guards then guards(world)
        when :to_furrier then go(world, 'furrier', next_phase: :furrier)
        when :furrier then furrier(world)
        when :hunt then hunt_over(world)
        when :turn_in_wait then turn_in_wait(world)
        when :heal then heal(world)
        when :sell then sell(world)
        when :to_bank then go(world, 'bank', next_phase: :bank)
        when :bank then bank(world)
        when :script then wait_script(world)
        when :wait_cooldown then wait_cooldown(world)
        when :finish then finish(world)
        end
      end

      private

      # bounty_check 2305-2366: where to next, from the task.
      def check(world)
        @task = world.bounty_task
        @hunting = false
        @rested = false
        @bandits = false
        stage = EO::Engine::Objective::Bounty::Predicates.stage(@task)
        Events.emit(:bounty_stage, stage: stage, type: @task&.type, text: world.bounty_text)
        if stage != :none && EO::Engine::Objective::Bounty::Predicates.remove?(@task, @policy)
          Events.emit(:bounty_removing, type: @task.type)
          return start_ask(:remove)
        end
        case stage
        when :none
          if world.cooldown_minutes_left('Next Bounty').positive?
            @phase = :wait_cooldown
            nil
          else
            start_ask(:get)
          end
        when :done then @phase = :turn_in_wait; nil
        when :failed then start_ask(:failure)
        when :guard
          @guard_rooms = EO::Engine::Objective::Bounty::Predicates.guard_rooms(world, @task.town)
          if @guard_rooms.empty?
            Events.emit(:bounty_error, reason: "no guard rooms for #{@task.town}")
            @hooks[:stop].call(:no_guard)
            return nil
          end
          @phase = :guards
          nil
        when :furrier then @phase = :to_furrier; nil
        when :hunt then start_hunt(world)
        else
          Events.emit(:bounty_unsupported, type: @task.type, text: world.bounty_text)
          @hooks[:stop].call(:unsupported_bounty)
          nil
        end
      end

      def start_ask(kind)
        @ask = kind
        @attempts = 0
        @phase = :to_guild
        nil
      end

      # One trip, a tick at a time.
      def go(world, place, next_phase:)
        case EO::Engine::Travel.step(self, @travel, place, world)
        when :underway then nil
        when :arrived
          @phase = next_phase
          Actions::Result.new(status: :success)
        else
          Events.emit(:bounty_error, reason: "could not reach #{place}")
          @hooks[:stop].call(:could_not_reach)
          Actions::Result.new(status: :failed, reason: :could_not_reach)
        end
      end

      # ask_taskmaster 2538-2569: until the type changes, five tries.
      def ask(world)
        result = Actions::AskTaskmaster.new(world, kind: @ask, boost_type: @policy.boost_type, clock: @clock).call
        @attempts += 1
        task = world.bounty_task
        settled = case @ask
                  when :get then !task.none?
                  when :turn_in, :failure, :remove then task.none?
                  else true
                  end
        if settled || result.reason == :already_assigned || result.reason == :ready
          after_ask
          return result
        end
        if @attempts >= EO::Engine::Objective::Bounty::ASK_ATTEMPTS
          Events.emit(:bounty_error, reason: "the taskmaster's answer did not change after #{@attempts} asks")
          @hooks[:stop].call(:taskmaster)
        end
        result
      end

      def after_ask
        case @ask
        when :remove
          if @policy.use_vouchers
            start_ask(:expedite)
          else
            @phase = :check
          end
        when :turn_in, :failure
          @phase = @policy.basic ? :to_bank : :heal
        when :get then @phase = @got_next ? :finish : :check
        else @phase = :check
        end
      end

      # ask_guard 2661-2732: each guard room in turn until one answers.
      def guards(world)
        room = @guard_rooms.first
        if room.nil?
          Events.emit(:bounty_error, reason: 'no guard answered')
          @hooks[:stop].call(:no_guard)
          return nil
        end
        room = 'u7503253' if [7503252, 7503251].include?(world.room_uid(room)) # Hinterwilds: the alchemist
        return go(world, room, next_phase: :guards) unless at?(world, room)

        result = Actions::AskGuard.new(world, clock: @clock).call
        if result.success?
          @phase = :check
        else
          @guard_rooms.shift
        end
        result
      end

      def at?(world, place)
        place.to_s =~ /\Au(\d+)\z/i ? world.room.uid.to_s == Regexp.last_match(1) : world.room.id == place.to_i
      end

      def furrier(world)
        result = Actions::AskNpc.new(world, names: EO::Engine::Objective::Bounty::FURRIER_NAMES, clock: @clock).call
        @attempts += 1
        if result.success?
          @phase = :check
        elsif @attempts >= EO::Engine::Objective::Bounty::ASK_ATTEMPTS
          Events.emit(:bounty_error, reason: 'the furrier did not answer')
          @hooks[:stop].call(:furrier)
        end
        result
      end

      # go_hunting 2264-2289 and switch_profile 703: the creature's
      # profile, its targets narrowed, the bandit area, Ranger tracking.
      def start_hunt(world)
        creature = @task.type == :bandit ? 'bandits' : @task.requirements[:creature].to_s
        found = @policy.profile_for(creature)
        if found.nil?
          if @policy.keep_hunting && @policy.default_profile
            found = [@policy.default_profile, false]
          else
            Events.emit(:bounty_error, reason: "no profile for #{creature}")
            @hooks[:stop].call(:no_profile)
            return nil
          end
        end
        profile, only = found
        @bandits = creature == 'bandits'
        area = nil
        if @bandits
          area = EO::Engine::Objective::Bounty::Predicates.location_area(world, @task.requirements[:area], bad_rooms: @policy.bad_rooms)
          if area.nil?
            Events.emit(:bounty_error, reason: "no rooms for #{@task.requirements[:area]}")
            @hooks[:stop].call(:no_location)
            return nil
          end
        end
        @home = world.room.id
        @hunting = true
        @rested = false
        @keep_hunting = false
        @group&.reset_bounty!
        Events.emit(:bounty_hunt, profile: profile, creature: creature, only: only, area: area && area[:rooms].size)
        @hooks[:switch].call(profile, creature: creature, only: only, bandits: @bandits, area: area,
                                      track: @policy.ranger_track && !@bandits ? creature.split.last : nil, wander_wait: @policy.wander_wait)
        @phase = :hunt
        Actions::Result.new(status: :success, reason: :hunting)
      end

      # The task's own completion, or the skin count.
      def hunt_done?(world)
        state = EO::Engine::Objective::Bounty::Predicates.state(world, @policy)
        %i[complete failed].include?(state)
      end

      # Control is ours again after a hunt.
      def hunt_over(world)
        stage = EO::Engine::Objective::Bounty::Predicates.stage(world.bounty_task)
        @phase = if stage == :none then :check
                 elsif stage == :hunt then :turn_in_wait # a skin count reached
                 else :turn_in_wait
                 end
        nil
      end

      # bounty_complete 2817-2831: not while saturated (unless keep_hunting).
      def turn_in_wait(world)
        if world.me.saturated? && !@policy.keep_hunting
          if @noticed_at.nil? || @clock.now - @noticed_at > 60
            @noticed_at = @clock.now
            Events.emit(:bounty_waiting, reason: 'mind saturated')
          end
          sleep 1
          return nil
        end
        stage = EO::Engine::Objective::Bounty::Predicates.stage(world.bounty_task)
        return start_ask(:failure) if stage == :failed
        return start_ask(:turn_in) if stage == :done

        # skin_bounty 3563-3569: the skins are sold, which completes the task
        @phase = stage == :hunt && world.bounty_task.type == :skin ? :heal : :check
        nil
      end

      # prep 3576-3589: heal when hurt, sell, bank, back.
      def heal(world)
        @home ||= world.room.id
        if !@policy.skip_healing && world.me.hurt?
          return run_script(@policy.healing_script, nil, next_phase: :sell)
        end

        @phase = :sell
        nil
      end

      def sell(_world)
        run_script(@policy.selling_script, 'sell', next_phase: :to_bank)
      end

      def run_script(name, args, next_phase:)
        @script = name.to_s.split(/\s+/).first
        @after_script = next_phase
        @scripts.start(@script, args)
        Events.emit(:bounty_script, script: @script, args: args)
        @phase = :script
        Actions::Result.new(status: :success)
      end

      def wait_script(_world)
        return nil if @scripts.running?(@script)

        @phase = @after_script
        nil
      end

      # silver_deposit 812-832, then home and the next check.
      def bank(world)
        silver = world.silver.to_i
        amount = silver - @policy.keep_silver.to_i
        result = amount.positive? ? Actions::Deposit.new(world, amount: amount).call : nil
        @phase = @policy.once_and_done ? :finish : :check
        result
      end

      # should_hunt? 2012-2024 and wait_for_bounty 3629: with keep_hunting,
      # hunt the default profile through the cooldown; else hold.
      def wait_cooldown(world)
        left = world.cooldown_minutes_left('Next Bounty')
        if left <= 0
          @phase = :check
          return nil
        end
        if @policy.keep_hunting && @policy.default_profile
          @keep_hunting = true
          @hunting = true
          @hooks[:switch].call(@policy.default_profile, creature: nil, only: false, bandits: false, area: nil, track: nil, wander_wait: nil)
          @phase = :hunt
          return Actions::Result.new(status: :success, reason: :keep_hunting)
        end
        if @noticed_at.nil? || @clock.now - @noticed_at > 60
          @noticed_at = @clock.now
          Events.emit(:bounty_waiting, reason: format('next bounty in %d minutes', left.ceil))
        end
        sleep 1
        nil
      end

      # once_and_done 2838-2843 (and get_new_bounty_before_exit 3611).
      def finish(world)
        if @policy.new_bounty_on_exit && !@got_next
          left = world.cooldown_minutes_left('Next Bounty')
          if left.positive?
            sleep 1
            return nil
          end
          @got_next = true
          return start_ask(:get)
        end
        @hooks[:stop].call(:once_and_done)
        nil
      end
    end
  end
end
