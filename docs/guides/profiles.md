# Profiles

eohunter reads bigshot profiles unchanged: the YAML that bsprofiles
writes to `data/<game>/<char>/bigshot_profiles/<name>.yaml`. This page
lists every key the engine honours, how its value is read, its default
when blank, and which behavior uses it. Keys not listed are ignored.

Values are cleaned the way bigshot's `clean_value` does. A missing or
blank value is the default for every type, booleans included.

## Value types

| Type | Reading |
|---|---|
| int, float | `to_i` / `to_f` |
| bool | `true` only for the value `true` or the text "true" |
| string | as text |
| stance | lowercased: offensive, advance, forward, neutral, guarded, defensive |
| room | a Lich room id, or `u<uid>` for a game UID resolved through the map (the first matching Lich id) |
| rooms | a comma-separated list of the above |
| split | comma-separated list |
| split_xx | comma-separated commands, each with an optional repeat: `cmd(x3)` repeats three times, `cmd(xx)` five; `a and b` inside one entry is one line that sends both |
| targets | comma-separated names, each optionally suffixed with a routine letter `(b)` through `(j)`; no letter means routine `a` |
| regex | the text as a case-insensitive pattern |

## Rooms and travel

| Key | Type | Default | Used by |
|---|---|---|---|
| `hunting_room_id` | room | none | Wander: the area's anchor and the walk out; Rest: the walk back to hunting |
| `hunting_boundaries` | rooms | none | Wander: the rooms that bound the area; Flee: the rooms it may flee into |
| `resting_room_id` | room | none | Rest: where to rest |
| `return_waypoint_ids` | rooms | none | Rest: rooms visited in order on the way home |
| `rallypoint_room_ids` | rooms | none | Rest (group): where the leader gathers followers before hunting |
| `fog_return` | int | 0 | Rest: the fog method on the way home (Lich's Fog methods 1 to 5, or 6 for `custom_fog`) |
| `custom_fog` | split_xx | none | Rest: the commands for fog method 6 |
| `fog_optional` | bool | false | Rest: walk when the fog cannot be cast |
| `fog_rift` | bool | false | Rest: the Rift's second cast |
| `wander_wait` | float | 0.3 | Wander: seconds between steps |
| `ignore_disks` | bool | false | Wander: do not wait for a disk to follow |
| `sneaky_sneaky` | bool | false | Wander and Rest: hide before stepping, `movement autosneak` on trips |

## Resting

| Key | Type | Default | Used by |
|---|---|---|---|
| `fried` | int | 100 | Rest: mind percent at which to rest |
| `overkill` | int | 0 | Rest: kills past fried before resting |
| `lte_boost` | int | 0 | Rest: `boost longterm` uses per rest |
| `oom` | int | 0 | Rest and Engage: mana below which a spell routine rests |
| `encumbered` | int | 101 | Rest: encumbrance percent at which to rest |
| `wounded_eval` | string | none | Rest: a Ruby expression evaluated in the script; true means rest |
| `creeping_dread`, `crushing_dread` | int | 0 | Rest: the dread stack at which to rest |
| `wot_poison` | bool | false | Rest: rest on Wall of Thorns poison |
| `confusion` | bool | false | Rest: rest when confused |
| `box_in_hand` | bool | false | Loot and Rest: rest holding a box |
| `rest_till_exp` | int | 0 | Rest: mind percent to rest down to |
| `rest_till_mana`, `rest_till_spirit` | int | 0 | Rest: the value to rest up to |
| `rest_till_percentstamina` | int | 0 | Rest: stamina percent to rest up to |
| `resting_commands` | split_xx | none | Rest: sent at the resting room |
| `resting_scripts` | split | none | Rest: started at the resting room, killed when hunting resumes |
| `use_wracking` | bool | false | Maintain and Engage: Voln's wrack when mana is short |
| `wracking_spirit` | int | 0 | Maintain and Engage: spirit to keep when wracking |
| `final_loot` | bool | false | Rest: a final loot pass before leaving |

## Hunting

| Key | Type | Default | Used by |
|---|---|---|---|
| `hunting_prep_commands` | split_xx | none | Rest: sent before walking out |
| `hunting_scripts` | split | none | Rest: started before walking out, stopped at rest |
| `hunting_stance` | stance | defensive | Engage: set before each routine line that needs it |
| `wander_stance` | stance | defensive | Wander, Loot, Rest, Survival: the stance between fights |
| `stand_stance` | stance | defensive | Survival: the stance to stand up in |
| `signs` | split | none | Maintain: the signs, spells and symbols to keep up; `650 panther evoke` style entries work |
| `bless` | bool | false | Maintain: Voln's bless on the weapon |
| `check_favor` | bool | false | Maintain: skip a symbol the favor cannot pay for |
| `priority` | bool | false | Engage: the first target in the profile's order rather than the nearest |
| `targets` | targets | none | Targets: what to fight and with which routine |
| `quickhunt_targets` | targets | none | Targets: the quick routine's targets |
| `invalid_targets` | split | none | Targets: never these |
| `boons_ignore` | list | none | Targets: ASSESS abilities that make a creature not worth fighting |
| `boons_flee` | list | none | Flee: ASSESS abilities that mean leave |
| `hunting_commands` and `hunting_commands_b` to `_j` | split_xx | none | Engage: routines a to j; see [Routines](routines.md) |
| `quick_commands` | split_xx | none | Engage: the quick routine (bandit mode) |
| `disable_commands` | split_xx | none | Engage: the routine a fried group member runs |
| `ambush` | split | none | Engage: the body parts for `ambush` lines, in order |
| `archery_aim` | split | none | Engage: the parts for `fire` |
| `aim` | split | none | Engage: the parts for unarmed aiming |
| `tier3` | string | punch | Engage: the unarmed tier-3 attack |
| `uac_smite`, `uac_mstrike` | bool | false | Engage: unarmed extras |
| `mstrike_cooldown`, `mstrike_quickstrike` | bool | false | Engage: mstrike behaviour on cooldown |
| `mstrike_stamina_cooldown`, `mstrike_stamina_quickstrike` | int | none | Engage: stamina floors for the above |
| `mstrike_mob` | int | 2 | Engage: creatures present before mstrike is worth it |
| `ammo_container` | string | none | Engage: where a refused fire stows its ammo; blank means the game's STOW DEFAULT |
| `ammo` | string | none | Maintain: the ammo noun to keep count of |
| `wand` | split | none | Engage: the wand nouns, in order |
| `wand_if_oom` | bool | false | Engage: wave a wand in a spell's place when it is unaffordable |
| `fresh_wand_container`, `dead_wand_container` | string | none | Engage: wandolier's containers |
| `weapon_reaction` | bool | true | Engage: the weapon reaction line |
| `loot_script` | string | none | Loot: a script to loot with, instead of `loot` |
| `delay_loot` | bool | false | Loot: wait fifteen seconds after a kill before looting |
| `loot_stance` | bool | false | Loot: switch to the wander stance to loot |

## Fleeing and survival

| Key | Type | Default | Used by |
|---|---|---|---|
| `flee_count` | int | 100 | Flee: creatures present at which to leave |
| `lone_targets_only` | bool | false | Flee: leave when a second creature joins a fight |
| `always_flee_from` | split | none | Flee: names that always mean leave |
| `flee_message` | regex | none | Flee: a game line that means leave |
| `flee_clouds`, `flee_vines`, `flee_webs`, `flee_voids` | bool | false | Flee: hazards that mean leave |
| `pull` | bool | true | Survival: pull a prone group member up |
| `deader` | bool | false | Survival: stop for a dead player in the room during the hunt |
| `dead_man_switch` | bool | false | Survival: quit on death |
| `depart_switch` | bool | false | Survival: depart on death |
| `troubadours_rally` | bool | false | Cleanse: 1040 on ourselves and the group |

## Group hunting

| Key | Type | Default | Used by |
|---|---|---|---|
| `independent_travel` | bool | false | Group: followers walk out on their own |
| `independent_return` | bool | false | Group: followers walk home on their own |
| `group_deader` | bool | false | Group: the leader stops for a dead member |
| `ma_looter` | string | none | Group: who loots |
| `never_loot` | split_xx | none | Group: members who never loot |
| `random_loot` | bool | false | Group: a random looter each fight |
| `quiet_followers` | bool | true | Group: followers do not print the leader's orders |
| `group_fried_trigger` | split | any | Group: `any`, `all`, or names; whose fried brings the group home |

## Cleanse

Cleanse reads `ecleanse.yaml` in the character directory, not the
bigshot profile, with ecleanse's own keys: which afflictions to treat,
which hazards to dispel, disarm recovery, hive traps. ecleanse's setup
window writes that file; eohunter never does.
