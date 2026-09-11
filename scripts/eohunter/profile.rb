# frozen_string_literal: true

# ============================================================================
# profile (a bigshot profile YAML into the engine's policies)
# ============================================================================

#
# bigshot keeps one YAML per profile under data/<game>/<char>/
# bigshot_profiles and reads every key through load_settings (2833) and
# clean_value (2972): "split" is a comma list, "split_xx" a comma list
# with (xN) and (xx) repeats and "a and b" arrays, "targets" a name(letter)
# list, to_i / to_f, and "u1234" room uids resolve to ids. The engine reads
# the same file with the same rules and hands each behavior its Policy,
# so a profile that runs under bigshot runs here unchanged. Rules in
# hunting-engine-plan.md, "Profile compatibility".
#
module EO::Engine
  # A bigshot profile YAML read with load_settings' rules, handed out as
  # one Policy per behavior. `self[key]` is the cleaned value.
  #
  # @bigshot load_settings 2833
  # @bigshot clean_value 2972
  class Profile
    # load_settings' rule per key: [cleaner, default]
    #
    # @bigshot load_settings 2833
    RULES = {
      'return_waypoint_ids' => [:rooms, []], 'resting_room_id' => [:room, nil], 'resting_commands' => [:split_xx, []],
      'resting_scripts' => [:split, []], 'fog_return' => [:to_i, 0], 'custom_fog' => [:split_xx, []],
      'fog_optional' => [:bool, false], 'fog_rift' => [:bool, false],
      'fried' => [:to_i, 100], 'overkill' => [:to_i, 0], 'lte_boost' => [:to_i, 0], 'oom' => [:to_i, 0],
      'encumbered' => [:to_i, 101], 'wounded_eval' => [:string, nil], 'creeping_dread' => [:to_i, 0],
      'crushing_dread' => [:to_i, 0], 'wot_poison' => [:bool, false], 'confusion' => [:bool, false], 'box_in_hand' => [:bool, false],
      'hunting_room_id' => [:room, nil], 'rallypoint_room_ids' => [:rooms, []], 'hunting_boundaries' => [:rooms, []],
      'rest_till_exp' => [:to_i, 0], 'rest_till_mana' => [:to_i, 0], 'rest_till_spirit' => [:to_i, 0], 'rest_till_percentstamina' => [:to_i, 0],
      'hunting_stance' => [:stance, 'defensive'], 'wander_stance' => [:stance, 'defensive'], 'stand_stance' => [:stance, 'defensive'],
      'hunting_right_hand' => [:string, 'keep'], 'hunting_left_hand' => [:string, 'keep'],
      'hunting_loadout_sets' => [:structured, {}], 'hunting_loadout_rules' => [:structured, []],
      'hunting_prep_commands' => [:split_xx, []], 'hunting_scripts' => [:split, []], 'signs' => [:split, []],
      'loot_script' => [:string, nil], 'wracking_spirit' => [:to_i, 0],
      'priority' => [:bool, false], 'delay_loot' => [:bool, false], 'use_wracking' => [:bool, false], 'loot_stance' => [:bool, false],
      'pull' => [:bool, true], 'deader' => [:bool, false], 'sneaky_sneaky' => [:bool, false], 'check_favor' => [:bool, false],
      'ambush' => [:split, []], 'archery_aim' => [:split, []], 'flee_count' => [:to_i, 100], 'invalid_targets' => [:split, []],
      'always_flee_from' => [:split, []], 'flee_message' => [:regex, nil], 'wander_wait' => [:to_f, 0.3],
      'flee_clouds' => [:bool, false], 'flee_vines' => [:bool, false], 'flee_webs' => [:bool, false], 'flee_voids' => [:bool, false],
      'bless' => [:bool, false], 'lone_targets_only' => [:bool, false], 'weapon_reaction' => [:bool, true],
      'hunting_commands' => [:split_xx, []], 'hunting_commands_b' => [:split_xx, []], 'hunting_commands_c' => [:split_xx, []],
      'hunting_commands_d' => [:split_xx, []], 'hunting_commands_e' => [:split_xx, []], 'hunting_commands_f' => [:split_xx, []],
      'hunting_commands_g' => [:split_xx, []], 'hunting_commands_h' => [:split_xx, []], 'hunting_commands_i' => [:split_xx, []],
      'hunting_commands_j' => [:split_xx, []], 'targets' => [:targets, {}], 'quickhunt_targets' => [:qtargets, {}],
      'quick_commands' => [:split_xx, []], 'disable_commands' => [:split_xx, []],
      'tier3' => [:string, 'punch'], 'aim' => [:split, []], 'uac_smite' => [:bool, false], 'uac_mstrike' => [:bool, false],
      'mstrike_stamina_cooldown' => [:to_i, nil], 'mstrike_stamina_quickstrike' => [:to_i, nil], 'mstrike_mob' => [:to_i, 2],
      'mstrike_cooldown' => [:bool, false], 'mstrike_quickstrike' => [:bool, false],
      'ammo_container' => [:string, nil], 'ammo' => [:string, nil], 'wand' => [:split, []], 'wand_if_oom' => [:bool, false],
      'fresh_wand_container' => [:string, nil], 'dead_wand_container' => [:string, nil],
      'final_loot' => [:bool, false], 'dead_man_switch' => [:bool, false], 'depart_switch' => [:bool, false],
      'ignore_disks' => [:bool, false], 'boons_ignore' => [:list, []], 'boons_flee' => [:list, []],
      'troubadours_rally' => [:bool, false],
      # MA Grouping (3549-3563)
      'independent_travel' => [:bool, false], 'independent_return' => [:bool, false], 'group_deader' => [:bool, false],
      'ma_looter' => [:string, nil], 'never_loot' => [:split_xx, []], 'random_loot' => [:bool, false], 'quiet_followers' => [:bool, true],
      'group_fried_trigger' => [:split, ['any']]
    }.freeze

    # The profile's name (the YAML's basename) and every RULES key with
    # its cleaned value.
    #
    # @return [String, nil, Hash{String => Object}]
    attr_reader :name, :settings

    # The profile YAML at +path+, named by its basename.
    #
    # @param path [String] the profile YAML
    # @param uid_ids [#call] (uid) -> [lich ids]; World#uid_ids
    # @return [Profile]
    def self.load(path, uid_ids: nil)
      require 'yaml'
      new(YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}, name: File.basename(path, '.yaml'), uid_ids: uid_ids)
    end

    # @param raw [Hash{String => Object}] the YAML as loaded
    # @param name [String, nil] the profile's name
    # @param uid_ids [#call, nil] (uid) -> [lich ids]; default answers
    #   none, so a "u1234" room resolves to nil
    def initialize(raw, name: nil, uid_ids: nil)
      @name = name
      @uid_ids = uid_ids || ->(_uid) { [] }
      @settings = RULES.to_h do |key, (cleaner, default)|
        value = cleaner == :structured ? raw.fetch(key, default) : raw[key]
        [key, clean(cleaner, value, default)]
      end
      @loadout_selection = Loadout::Selection.new(default: loadout_policy, sets: self['hunting_loadout_sets'], rules: self['hunting_loadout_rules'])
    end

    # The cleaned value for a RULES key; nil for a key not in RULES.
    #
    # @param key [String, Symbol]
    # @return [Object, nil]
    def [](key) = @settings[key.to_s]

    # --- the policies ------------------------------------------------------

    # The Rest behavior's Policy from the rest, fog, resting-room and
    # prep keys. rest_interval is fixed at 30.
    #
    # @param wounded_binding [Binding, nil] where wounded_eval runs (the
    #   script's binding, so bleeding?, Char and Injured resolve)
    # @return [Rest::Policy]
    def rest_policy(wounded_binding: nil)
      evaluator = self['wounded_eval'] && wounded_binding ? -> { eval(self['wounded_eval'], wounded_binding) ? true : false } : nil
      Rest::Policy.new(
        fried: self['fried'], overkill: self['overkill'], lte_boost: self['lte_boost'], oom: self['oom'], encumbered: self['encumbered'],
        use_wracking: self['use_wracking'], wracking_spirit: self['wracking_spirit'],
        creeping_dread: self['creeping_dread'], crushing_dread: self['crushing_dread'], wot_poison: self['wot_poison'],
        confusion: self['confusion'], wounded: evaluator,
        rest_till_exp: self['rest_till_exp'], rest_till_mana: self['rest_till_mana'], rest_till_spirit: self['rest_till_spirit'],
        rest_till_stamina: self['rest_till_percentstamina'],
        resting_room: self['resting_room_id'], return_waypoints: self['return_waypoint_ids'], hunting_room: self['hunting_room_id'],
        rally_rooms: self['rallypoint_room_ids'], fog_return: self['fog_return'], fog_optional: self['fog_optional'],
        fog_rift: self['fog_rift'], custom_fog: self['custom_fog'],
        resting_commands: self['resting_commands'], resting_scripts: self['resting_scripts'],
        hunting_prep_commands: self['hunting_prep_commands'], hunting_scripts: self['hunting_scripts'],
        wander_stance: self['wander_stance'], rest_interval: 30, sneaky: self['sneaky_sneaky']
      )
    end

    # The Targets Policy from targets, invalid_targets and boons_ignore.
    #
    # @param untargetable [Array<String>] names the game refused to
    #   TARGET, persisted by the caller
    # @return [Targets::Policy]
    def targets_policy(untargetable: [])
      Targets::Policy.new(wanted: self['targets'], invalid: self['invalid_targets'], untargetable: untargetable,
                          boons_ignore: self['boons_ignore'])
    end

    # The Flee Policy from flee_count, the hazard toggles, always_flee_from,
    # boons_flee, flee_message and hunting_boundaries.
    #
    # @return [Flee::Policy]
    def flee_policy
      Flee::Policy.new(flee_count: self['flee_count'], lone_targets_only: self['lone_targets_only'], always_flee_from: self['always_flee_from'],
                       clouds: self['flee_clouds'], vines: self['flee_vines'], webs: self['flee_webs'], voids: self['flee_voids'],
                       boons_flee: self['boons_flee'], message: self['flee_message'], boundaries: self['hunting_boundaries'])
    end

    # The Wander Policy from hunting_room_id, hunting_boundaries,
    # wander_wait, sneaky_sneaky, ignore_disks and wander_stance.
    #
    # @return [Wander::Policy]
    def wander_policy
      Wander::Policy.new(hunting_room: self['hunting_room_id'], boundaries: self['hunting_boundaries'], wander_wait: self['wander_wait'],
                         sneaky: self['sneaky_sneaky'], ignore_disks: self['ignore_disks'], wander_stance: self['wander_stance'])
    end

    # The Loot Policy from loot_script, delay_loot, loot_stance,
    # final_loot and box_in_hand.
    #
    # @return [Loot::Policy]
    def loot_policy
      Loot::Policy.new(script: self['loot_script'], delay: self['delay_loot'], stance: self['loot_stance'], final: self['final_loot'],
                       box_in_hand: self['box_in_hand'])
    end

    # The optional hunting hand baseline. Missing and blank keys resolve to
    # keep/keep, so existing bigshot profiles remain unmanaged.
    #
    # @return [Loadout::Policy]
    def loadout_policy
      Loadout::Policy.new(right: self['hunting_right_hand'], left: self['hunting_left_hand'])
    end

    # Named sets and ordered target rules, validated during profile loading.
    # The legacy hunting hands remain the default policy.
    #
    # @return [Loadout::Selection]
    def loadout_selection = @loadout_selection

    # The Maintain Policy from signs, bless, use_wracking,
    # wracking_spirit, check_favor and ammo.
    #
    # @return [Maintain::Policy]
    def maintain_policy
      Maintain::Policy.new(signs: self['signs'], bless: self['bless'], use_wracking: self['use_wracking'],
                           wracking_spirit: self['wracking_spirit'], check_favor: self['check_favor'], ammo: self['ammo'])
    end

    # The Survival Policy from stand_stance, pull, deader and
    # group_deader; on_death is :depart with depart_switch, else :quit
    # with dead_man_switch, else :stop.
    #
    # @return [Survival::Policy]
    def survival_policy
      on_death = if self['depart_switch'] then :depart
                 elsif self['dead_man_switch'] then :quit
                 else :stop
                 end
      Survival::Policy.new(stand_stance: self['stand_stance'], pull: self['pull'], deader: self['deader'],
                           group_deader: self['group_deader'], on_death: on_death)
    end

    # The Group Policy from the MA Grouping keys; never_loot is
    # flattened out of its split_xx arrays.
    #
    # @return [Group::Policy]
    # @bigshot MA Grouping 3549
    def group_policy
      Group::Policy.new(independent_travel: self['independent_travel'], independent_return: self['independent_return'],
                        group_deader: self['group_deader'], looter: self['ma_looter'], quiet_followers: self['quiet_followers'],
                        never_loot: self['never_loot'].flatten, random_loot: self['random_loot'], fried_trigger: self['group_fried_trigger'])
    end

    # The Engage Policy: hunting_commands as routine 'a' and
    # hunting_commands_b..j as 'b'..'j', with the quick and disable
    # commands, the stances, the wand, ammo, aim and mstrike keys.
    #
    # @return [Engage::Policy]
    def engage_policy
      routines = { 'a' => self['hunting_commands'] }
      ('b'..'j').each { |l| routines[l] = self["hunting_commands_#{l}"] }
      Engage::Policy.new(routines: routines, quick_commands: self['quick_commands'], disable_commands: self['disable_commands'],
                         priority: self['priority'], hunting_stance: self['hunting_stance'], wander_stance: self['wander_stance'],
                         wand_if_oom: self['wand_if_oom'], use_wracking: self['use_wracking'], wracking_spirit: self['wracking_spirit'],
                         oom: self['oom'], ambush: self['ambush'],
                         archery_aim: self['archery_aim'], aim: self['aim'], tier3: self['tier3'], uac_smite: self['uac_smite'],
                         uac_mstrike: self['uac_mstrike'], ammo_container: self['ammo_container'],
                         fresh_wand_container: self['fresh_wand_container'], dead_wand_container: self['dead_wand_container'],
                         wand: self['wand'], weapon_reaction: self['weapon_reaction'])
    end

    # The Mstrike Policy from the mstrike_* keys.
    #
    # @return [Actions::Mstrike::Policy]
    def mstrike_policy
      Actions::Mstrike::Policy.new(cooldown: self['mstrike_cooldown'], quickstrike: self['mstrike_quickstrike'],
                                   stamina_cooldown: self['mstrike_stamina_cooldown'], stamina_quickstrike: self['mstrike_stamina_quickstrike'],
                                   mob: self['mstrike_mob'])
    end

    private

    # clean_value (3578), plus the uid resolution bigshot does in
    # convert_from_uid (3025). A missing or blank value is the default
    # for every type (3629-3633), booleans included: pull, weapon_reaction
    # and quiet_followers default to true.
    #
    # @bigshot clean_value 3578
    # @bigshot convert_from_uid 3025
    def clean(cleaner, value, default)
      return value if cleaner == :structured

      blank = value.nil? || (value.respond_to?(:empty?) && value.empty?) || value.to_s =~ /\A\s*\z/
      return default if blank

      case cleaner
      when :to_i then value.to_i
      when :to_f then value.to_f
      when :bool then value == true || value.to_s =~ /\Atrue\z/i ? true : false
      when :string then value.to_s
      # bigshot's flee_message (6879): the text is a case-insensitive
      # pattern against each game line
      when :regex then Regexp.new(value.to_s, Regexp::IGNORECASE)
      when :stance then value.to_s.downcase
      when :split then value.to_s.split(/,\s*/)
      when :list then value.is_a?(Array) ? value.map(&:to_s) : value.to_s.split(/,\s*/)
      when :room then room_id(value)
      when :rooms then value.to_s.split(/,\s*/).map { |v| room_id(v) }.compact
      when :split_xx then split_xx(value.to_s)
      when :targets, :qtargets then targets(value.to_s, cleaner == :targets ? 'a' : 'quick')
      else value
      end
    end

    def room_id(value)
      v = value.to_s.strip
      return v.to_i if v =~ /\A\d+\z/
      return @uid_ids.call(v[1..].to_i).first if v =~ /\Au\d+\z/i

      v.empty? ? nil : v
    end

    def split_xx(value)
      value.split(/,\s*/).flat_map do |entry|
        rep = 1
        cmd = entry
        if entry =~ /(.*)\(x(\d+)\)$/i
          rep = Regexp.last_match(2).to_i
          cmd = Regexp.last_match(1)
        elsif entry =~ /(.*)\(xx\)/i
          rep = 5
          cmd = Regexp.last_match(1)
        end
        ands = cmd.split(/\sand\s/)
        cmd = ands.size == 1 ? ands[0] : ands
        Array.new(rep, cmd)
      end
    end

    def targets(value, default)
      value.split(/,/).each_with_object({}) do |entry, h|
        if entry =~ /(.*)\(([a-jA-J])\)/
          h[Regexp.last_match(1).downcase.strip] = Regexp.last_match(2).downcase.strip
        else
          h[entry.downcase.strip] = default
        end
      end
    end
  end
end
