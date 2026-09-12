# frozen_string_literal: true

# ============================================================================
# objective (ebounty's cycle for the hunting bounties, inside the engine)
# ============================================================================

#
# ebounty 1.11.2 is a loop over Lich's Bounty task (Task.bounty_check
# 2305): nothing assigned, ask the taskmaster; an assignment,
# ask the guard or the furrier for the details; a task,
# switch to the creature's bigshot profile and run bigshot bounty
# until its bounty_eval says done; done, rest, turn in,
# heal, sell, bank; repeat. The engine's Objective::Bounty
# is that cycle as a behavior at priority 18, above Rest: the town
# phases are its own trips and actions, one per tick; the hunt is the
# engine's other behaviors on the creature's profile, which the script
# swaps in through a hook; when the task is done the objective waits
# for Rest to bring us home, then does the town. The bounty types that
# are hunts (cull, dangerous, bandit, skin) run here; gem, herb, heirloom,
# escort and rescue are refused or removed and stay ebounty's. Rules and
# ebounty line references in hunting-engine-plan.md, "Bounty objective".
#
# This file is kept in the repo but not loaded by the engine: ebounty
# stays the bounty driver, and eohunter is only its hunt child. It is
# documented as it stands.
#
module EO::Engine
  # Long-running goals above Rest that decide what the hunt is for. Only
  # Bounty exists, and it is not loaded (ebounty drives bounties).
  module Objective
    # The bounty cycle's tables, policy and predicates, from ebounty 1.11.2.
    module Bounty
      # ebounty's crosswalk: Lich's task type to the setup's name.
      CROSSWALK = {
        bandit_assignment: 'kill_bandits', bandit: 'kill_bandits', creature_assignment: 'kill_creatures',
        cull: 'culling', dangerous: 'boss_culling', dangerous_spawned: 'boss_culling', escort: 'escort',
        gem_assignment: 'gem_collecting', gem: 'gem_collecting', heirloom_assignment: 'heirloom_both', heirloom: 'heirloom_both',
        herb_assignment: 'foraging', herb: 'foraging', rescue_assignment: 'rescue', rescue: 'rescue',
        skin_assignment: 'skinning', skin: 'skinning'
      }.freeze

      # What the engine hunts; the rest are ebounty's.
      HUNTED = %i[bandit cull dangerous dangerous_spawned skin].freeze
      # The assignment types that lead to a hunt, once the details are asked for.
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
      # The guard answers that mean no task here, or no guard at all.
      GUARD_NO_TASK = /I don't have any tasks for you right now|Try bugging me later|Who are you trying to ask\?/
      # The room objects a guard may be listed as (ebounty's guard names).
      GUARD_NAMES = /(?:guard|sergeant|guardsman|sentry|tavernkeeper|alchemist|Malovor)/i
      # ebounty 921
      FURRIER_NAMES = /Bramblefist|Delosa|dwarven clerk|furrier|patchwork flesh merchant/i
      # The bandit creature nouns, as a pattern fragment for a target filter.
      BANDIT_NOUNS = '(?:thief|rogue|bandit|mugger|outlaw|highwayman|marauder|brigand|thug|robber)'
      # The most rooms a bandit area is capped to (ebounty 2303).
      MAX_CRAWL_ROOMS = 100 # ebounty 2303
      # Asks of the taskmaster or furrier before giving up (ebounty 2463, 2510).
      ASK_ATTEMPTS = 5 # ebounty 2463, 2510

      # ebounty.yaml, the keys the hunting cycle reads. Profiles are the
      # per-letter creature lists (names_a, profile_a, kill_a; 703-729).
      #
      # @!attribute types
      #   @return [Array<String>] bounty_types: the setup names wanted
      # @!attribute default_profile
      #   @return [String, nil] the profile hunted with keep_hunting
      # @!attribute bandits_profile
      #   @return [String, nil] the profile for bandit tasks
      # @!attribute kill_bandits
      #   @return [Boolean] hunt only the bandits on a bandit task
      # @!attribute profiles
      #   @return [Hash{String => Hash}] letter => :names, :profile, :kill
      # @!attribute creature_exclude
      #   @return [Array<String>] creature names to remove, lowercased
      # @!attribute location_exclude
      #   @return [Array<String>] area names to remove, lowercased
      # @!attribute exp_pause
      #   @return [Boolean] rest as soon as the task is done
      # @!attribute keep_hunting
      #   @return [Boolean] hunt the default profile through the cooldown
      # @!attribute once_and_done
      #   @return [Boolean] stop after one bounty
      # @!attribute new_bounty_on_exit
      #   @return [Boolean] take the next task before stopping
      # @!attribute selling_script
      #   @return [String] the script run to sell, default eloot
      # @!attribute healing_script
      #   @return [String] the script run to heal, default eherbs
      # @!attribute skip_healing
      #   @return [Boolean] never run the healing script
      # @!attribute extra_skin
      #   @return [Integer] skins gathered beyond the task's count
      # @!attribute use_vouchers
      #   @return [Boolean] expedite after a removal
      # @!attribute boost_type
      #   @return [String, nil] the Bounty Boost kind asked for
      # @!attribute ranger_track
      #   @return [Boolean] a Ranger tracks the bounty creature
      # @!attribute wander_wait
      #   @return [Float] seconds between wander steps, handed to the hunt
      # @!attribute bad_rooms
      #   @return [Array<Integer>] lich room ids left out of a bandit area
      # @!attribute keep_silver
      #   @return [Integer] silver kept back from the deposit
      # @!attribute basic
      #   @return [Boolean] bank straight after the turn-in, no heal or sell
      Policy = Struct.new(:types, :default_profile, :bandits_profile, :kill_bandits, :profiles, :creature_exclude, :location_exclude,
                          :exp_pause, :keep_hunting, :once_and_done, :new_bounty_on_exit, :selling_script, :healing_script, :skip_healing,
                          :extra_skin, :use_vouchers, :boost_type, :ranger_track, :wander_wait, :bad_rooms, :keep_silver, :basic,
                          keyword_init: true) do
        def initialize(types: [], default_profile: nil, bandits_profile: nil, kill_bandits: false, profiles: {}, creature_exclude: [],
                       location_exclude: [], exp_pause: false, keep_hunting: false, once_and_done: false, new_bounty_on_exit: false,
                       selling_script: 'eloot', healing_script: 'eherbs', skip_healing: false, extra_skin: 0, use_vouchers: false,
                       boost_type: nil, ranger_track: false, wander_wait: 0.5, bad_rooms: [], keep_silver: 0, basic: false) = super

        # The policy from an ebounty.yaml file; a missing file is empty.
        #
        # @param path [String] the yaml file
        # @param uid_ids [#call] (uid) -> [lich ids], for the bad rooms
        # @return [Policy]
        def self.load(path, uid_ids: nil)
          require 'yaml'
          raw = File.exist?(path) ? (YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}) : {}
          from(raw, uid_ids: uid_ids)
        end

        # The policy from ebounty.yaml's hash: the letter profiles a..j,
        # bad_room1..12 resolved to lich ids, blanks to nil, flags to
        # booleans. keep_silver is not read here and stays 0.
        #
        # @param raw [Hash] the yaml contents, keys strings or symbols
        # @param uid_ids [#call, nil] (uid) -> [lich ids], for the bad rooms
        # @return [Policy]
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

        # A setting as a string, or nil when empty.
        #
        # @param value [Object, nil] the raw setting
        # @return [String, nil]
        def self.blank(value) = value.to_s.strip.empty? ? nil : value.to_s

        # A bad_room entry as a lich id: a number as is, a "u" uid through
        # +uid_ids+, anything else nil.
        #
        # @param value [String, Integer] the entry
        # @param uid_ids [#call, nil] (uid) -> [lich ids]
        # @return [Integer, nil]
        def self.room_id(value, uid_ids)
          v = value.to_s.strip
          return v.to_i if v =~ /\A\d+\z/
          return uid_ids&.call(v[1..].to_i)&.first if v =~ /\Au\d+\z/i

          nil
        end

        # switch_profile: the letter whose names match, else the
        # bandits profile, else nil (keep_hunting hunts the default).
        #
        # @param creature [String] the task's creature, or 'bandits'
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
        #
        # @param type [Symbol] Lich's task type
        # @return [Boolean] true when the types list asks for it, or it has no name
        def wanted?(type)
          name = CROSSWALK[type]
          return true if name.nil?
          return types.grep(/culling/).any? if name == 'kill_creatures'
          return types.include?('heirloom_loot') || types.include?('heirloom_search') if name == 'heirloom_both'

          types.include?(name)
        end
      end

      # The pure questions of the cycle: the stage, removal, skin counts,
      # the report state, the bandit area and the guard rooms.
      module Predicates
        module_function

        # Where the cycle is for a task (bounty_check 2317): :none, :done
        # (turn in), :failed, :guard (ask a guard), :furrier (ask the
        # furrier), :hunt, or :other (a type the engine does not run).
        #
        # @param task [#type, nil] Lich's Bounty task
        # @return [Symbol]
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
        #
        # @param task [#type, #none?, #requirements, nil] Lich's Bounty task
        # @param policy [Policy]
        # @return [Boolean] true for an excluded creature or area, or an unwanted type
        def remove?(task, policy)
          return false if task.nil? || task.none?

          req = task.requirements || {}
          return true if policy.creature_exclude.any? && req[:creature] && policy.creature_exclude.any? { |c| req[:creature].to_s.downcase =~ /#{Regexp.escape(c)}/ }
          return true if policy.location_exclude.any? && req[:area] && policy.location_exclude.any? { |c| req[:area].to_s.downcase =~ /#{Regexp.escape(c)}/ }

          !policy.wanted?(task.type)
        end

        # skin_bounty 3546-3563: skins in the containers against the count
        # (plus extra_skin); bundles are not measured.
        #
        # @param world [World] answers container_item_names
        # @param skin [String] the task's skin name, plural or not
        # @return [Integer] the items in the containers matching the singular
        def skins_have(world, skin)
          name = skin.to_s.strip.downcase.gsub(/s$/, '').gsub(/teeth/, 'tooth').gsub(/hooves?/, 'hoof')
          return 0 if name.empty?

          world.container_item_names.count { |n| n.downcase =~ /#{Regexp.escape(name)}/ }
        end

        # The task's count plus the policy's extra_skin.
        #
        # @param task [#requirements] Lich's Bounty task
        # @param policy [Policy]
        # @return [Integer]
        def skins_needed(task, policy) = task.requirements[:number].to_i + policy.extra_skin.to_i

        # The report's bounty state (the split plan's 3.1).
        #
        # @param world [World]
        # @param policy [Policy]
        # @param task [#type, nil] Lich's Bounty task; the world's by default
        # @return [Symbol] :none, :hunting, :complete or :failed
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
        #
        # @param world [World] answers rooms_in_location, nearest_reachable, exits_from
        # @param name [String] the task's area name
        # @param bad_rooms [Array<Integer>] lich ids left out
        # @return [Hash, nil] :start, :rooms, :boundaries; nil with no rooms or no start
        def location_area(world, name, bad_rooms: [])
          rooms = world.rooms_in_location(name) - bad_rooms
          return nil if rooms.empty?

          start = world.nearest_reachable(rooms)
          return nil if start.nil?

          rooms = crawl(world, start, rooms) if rooms.size > MAX_CRAWL_ROOMS
          boundaries = rooms.flat_map { |id| world.exits_from(id).keys.reject { |n| rooms.include?(n) } }.uniq
          { start: start, rooms: rooms, boundaries: boundaries }
        end

        # limit_crawl_area 2779: a breadth-first walk from +start+ through
        # the area's rooms, stopping at +max+.
        #
        # @param world [World] answers exits_from
        # @param start [Integer] the lich id to start from
        # @param rooms [Array<Integer>] the area's rooms
        # @param max [Integer] the most rooms to take
        # @return [Array<Integer>] the contiguous rooms reached, start first
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
        #
        # @param world [World] answers uid_ids, rooms_tagged, nearest_by_tag_from, routable?
        # @param town_name [String] the task's town, a TOWNS key
        # @return [Array<Integer>] the guard rooms' lich ids, empty for an unknown town
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
    # ask_taskmaster: ASK <taskmaster> ABOUT BOUNTY | REMOVAL |
    # EXPEDITING at the guild, confirmed by the bounty text changing
    # within three seconds (bounty_change 309); removal asks twice.
    class AskTaskmaster < Base
      # The ASK topic for each kind of ask.
      KINDS = { get: 'bounty', turn_in: 'bounty', failure: 'bounty', remove: 'removal', expedite: 'expediting' }.freeze
      # The Sailor's Grief room uids, where Seldit is the taskmaster and there is no advguild tag.
      SAILORS_GRIEF = [7150601, 7150602, 7150603, 7150604, 7150605, 7150606, 7150607, 7150608, 7150609, 7150610,
                       7150611, 7150612, 7150613, 7150614, 7150615, 7150616, 7150617, 7150621, 7150622].freeze

      # @param world [World]
      # @param kind [Symbol] a KINDS key: :get, :turn_in, :failure, :remove or :expedite
      # @param boost_type [String, nil] the Bounty Boost kind, added to a :get while boosted
      # @param clock [#now] the time source, for the three second wait
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, kind:, boost_type: nil, clock: Time, **opts)
        super(world, **opts)
        @kind = kind
        @boost_type = boost_type
        @clock = clock
      end

      # @return [Symbol] :ok, :dead, or :not_at_guild away from an advguild room or Sailor's Grief
      def preconditions
        return :dead if me.dead?
        return :not_at_guild unless @world.room.tags.include?('advguild') || SAILORS_GRIEF.include?(@world.room.uid.to_i)

        :ok
      end

      # find_taskmaster 2592-2596
      #
      # @return [String] the taskmaster's name here: Halfwhistle, Seldit or Taskmaster
      def taskmaster
        uid = @world.room.uid.to_i
        return 'Halfwhistle' if uid == 7503207
        return 'Seldit' if SAILORS_GRIEF.include?(uid)

        'Taskmaster'
      end

      # The ask, once (twice for a removal), then up to three seconds
      # for the bounty text to change. An "already been assigned" answer
      # and an expedite's "ready to assign" are successes in themselves.
      #
      # @return [Actions::Result] :changed, :already_assigned or :ready on success;
      #   :no_taskmaster failed; :no_change on timeout
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
      # @param world [World]
      # @param clock [#now] the time source, for the three second wait
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, clock: Time, **opts)
        super(world, **opts)
        @clock = clock
      end

      # The nouns to ask: the purser in River's Rest, else every room
      # object whose name matches GUARD_NAMES.
      #
      # @return [Array<String>]
      def guards
        return ['purser'] if @world.room_location(@world.room.id).to_s =~ /the town of River's Rest/

        @world.room.npcs_and_desc.select { |o| o.name.to_s =~ EO::Engine::Objective::Bounty::GUARD_NAMES }.map { |o| o.noun.to_s }
      end

      # @return [Symbol] :ok, :dead, or :no_guard when nothing here looks like one
      def preconditions
        return :dead if me.dead?
        return :no_guard if guards.empty?

        :ok
      end

      # Each guard in turn: a no-task answer moves to the next; any other
      # answer waits up to three seconds for the bounty text to change.
      #
      # @return [Actions::Result] :changed or :answered on success; :no_task_here when
      #   every guard said no; the failed send otherwise
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
      # @param world [World]
      # @param names [Regexp] the room objects to ask, FURRIER_NAMES for a skin task
      # @param clock [#now] the time source, for the three second wait
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, names:, clock: Time, **opts)
        super(world, **opts)
        @names = names
        @clock = clock
      end

      # @return [#id, #name, nil] the first room object whose name matches
      def npc = @world.room.npcs_and_desc.find { |o| o.name.to_s =~ @names }

      # @return [Symbol] :ok, :dead, or :no_npc when nothing here matches
      def preconditions
        return :dead if me.dead?
        return :no_npc if npc.nil?

        :ok
      end

      # ASK by id through the ladder, then up to three seconds for the
      # bounty text to change.
      #
      # @return [Actions::Result] :changed on success; :no_change on timeout; the failed send
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
      # The teller's answers to DEPOSIT, taken or refused.
      ANSWER = /You deposit|You hand|deposit|The teller|You don't have that much|What/i

      # @param world [World]
      # @param amount [Integer, String] the silver to deposit
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, amount:, **opts)
        super(world, **opts)
        @amount = amount.to_i
      end

      # @return [Symbol] :ok, :dead, or :nothing for a non-positive amount
      def preconditions
        return :dead if me.dead?
        return :nothing unless @amount.positive?

        :ok
      end

      # @return [Actions::Result] the matched answer, or a timeout
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
      # @option hooks [#call] :switch swaps the creature's profile into the engine
      # @option hooks [#call] :rest answers the current Rest behavior
      # @option hooks [#call] :stop stops the script with a reason
      # @param group [Group::Leader, nil]
      # @param travel [#call, nil] (place) -> Trip or Boolean; default a Travel trip
      # @param scripts [Object, nil] start(name, args), running?(name); default Rest::LichScripts
      # @param clock [#now] the time source
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

      # @!attribute [r] phase
      #   @return [Symbol] the cycle's phase: :check, :to_guild, :ask, :guards, :to_furrier,
      #     :furrier, :hunt, :turn_in_wait, :heal, :sell, :to_bank, :bank, :script,
      #     :wait_cooldown or :finish
      # @!attribute [r] task
      #   @return [Object, nil] Lich's Bounty task as of the last check
      attr_reader :phase, :task

      # @return [Integer] 18, above Rest
      def priority = 18

      # @return [String] 'bounty'
      def name = 'bounty'

      # Drop the trip in progress.
      #
      # @return [void]
      def cancel! = EO::Engine::Travel.cancel(self)
      # A higher behavior took over: suspend the trip to resume later.
      #
      # @param _world [World] unused
      # @return [void]
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      # The report's state for a group member.
      #
      # @param world [World]
      # @return [Symbol] :none, :hunting, :complete or :failed
      def state(world) = EO::Engine::Objective::Bounty::Predicates.state(world, @policy)

      # Always in a town phase. In the hunt: the group's verdict first (a
      # lost member ends the hunt), then ours again once the task is done
      # and Rest has us resting, or the task went away, or keep_hunting's
      # cooldown is over at rest. A done task rests at once with exp_pause
      # or on a bandit bounty.
      #
      # @param world [World]
      # @return [Boolean]
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

      # One step of the phase in progress.
      #
      # @param world [World]
      # @return [Actions::Result, nil] the step's result, nil when only waiting or moving phase
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
