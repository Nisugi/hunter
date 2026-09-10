# eohunter

A hunting script for Gemstone IV on Lich 5, built as an engine of small
behaviors rather than one long loop. It reads bigshot profiles unchanged,
so an existing profile runs here without edits, and it folds ecleanse in
as one of its behaviors.

## Running it

```
;eohunter <profile>                    hunt with data/<game>/<char>/bigshot_profiles/<profile>.yaml
;eohunter <profile> dry                load the profile, report the policies, do not run
;eohunter <profile> bandits            hunt bandits (also on when the bounty says so)
;eohunter <profile> track <creature>   Rangers: TRACK toward the creature before each step
;eohunter <profile> head <count>       lead a group: wait for <count> followers, then hunt
;eohunter <profile> head <name> ...    lead a group of these characters
;eohunter <profile> tail [uri]         follow a leader (the rally whisper names the uri)
```

`scripts/eohunter.lic` needs Lich 5.22 or newer with the PSM reader
methods from lich-5 #1583 (`CMan.command`, `CMan.results_regex` and their
siblings) and the Fog module from lich-5 #1584; on a Lich without that
module it loads `scripts/libeo.lic` for its fog return instead. Cleanse
reads `data/<game>/<char>/ecleanse.yaml`, which ecleanse's own setup
window writes. A profile's `troubadours_rally`, `signs` entries such as
`650 panther evoke`, and `quick_commands` (used by bandit mode) all work
as they do in bigshot.

Bandit mode narrows the target list to the bandit nouns on the quick
routine (list a when there are no quick commands), never switches
target, and does not flee past `always_flee_from`. It is also switched on
by a bounty that says "suppress bandit activity"; bounty completion is
still ebounty's job, which runs alongside.

Group hunting is bigshot's head and tail. The leader groups everyone in
the game, runs `head` with the follower count or their names, and
whispers a rally address to the group; each follower runs `tail` and
joins. The leader's profile decides the rooms, the looter (`ma_looter`,
`never_loot`, `random_loot`), `quiet_followers`, `independent_travel`,
`independent_return` and `group_deader`; each follower's own profile
decides its routines, prep commands and scripts. A follower that stops
answering is reported and no longer waited for; a follower whose leader
stops answering stops.

## How it works

Each tick, about four times a second, the engine asks every behavior in
priority order whether it wants control, and the most urgent one gets to
run one action. An action is a game command with its preconditions, its
roundtime wait, its send through bigshot's refusal ladder, and its
confirmation on the game's answer, returning a result the caller must
handle. Nothing sends a command and hopes.

| Priority | Behavior | From bigshot / ecleanse |
|---|---|---|
| 0 | Survival | dead, escape rooms, stand, pull, dead players and dead group members |
| 5 | Cleanse | all of ecleanse: afflictions, hazards, disarm recovery, hive traps; Troubadour's Rally for us and the group |
| 10 | Flee | `should_flee?` and the ambusher, one step out per tick |
| 15 | Muster | the leader's holds between fights: a stunned member, a missing follower |
| 20 | Rest / Orders | `ready_to_rest?` with the group's reasons, the final loot, the rest cycle with every follower wait, `ready_to_hunt?`; a follower runs the leader's orders instead |
| 30 | Loot | `need_to_loot?`, the looter, the loot script, the fried bookkeeping |
| 40 | Maintain | signs including Assume Aspect, bless, wrack |
| 50 | Engage / Assist | the routine language, one line per tick, every command check; a follower takes the leader's target first |
| 60 | Wander / Follow | the hunting area, the claim, the bandit look, Ranger tracking, one step per tick; a follower goes back to the leader and joins |

Control changes hands between ticks, and a behavior that loses it has
its trip suspended: the go2 script is killed and started again from
wherever we are when the behavior gets control back, so Flee or Cleanse
never issue commands while go2 is still walking.

The parts live in `scripts/eohunter/`, one file each, loaded in order by
`engine.rb`:

- `events.rb`, `world.rb`, `behavior.rb`, `runner.rb`: the control model.
  An event bus, a read-only facade over Lich's game state, the behavior
  contract, the tick loop with its watchdog.
- `actions.rb`, `combat.rb`, `maneuvers.rb`, `routines.rb`: the actions.
  The send ladder and the three confirmation shapes; attack and cast;
  maneuvers on Lich's PSM readers and mstrike; the rest of bigshot's
  routine vocabulary.
- `targets.rb`, `flee.rb`, `rest.rb`, `loot.rb`, `maintain.rb`,
  `survival.rb`, `engage.rb`, `wander.rb`, `cleanse.rb`: the behaviors,
  each with its policy and its predicates.
- `tracking.rb`: bandit mode and Ranger tracking, the policy and the
  three actions Wander uses.
- `group.rb`: the group. A Hub the leader serves over DRb, the leader's
  view of it, the follower's bounded link, and the follower's three
  behaviors (Orders, Assist, Follow) plus the leader's Muster.
- `watch.rb`: the one DownstreamHook, a rule table from line to event.
- `travel.rb`: the go2 script supervised a tick at a time, with one
  trip owning go2 and suspension on preemption.
- `profile.rb`: a bigshot profile YAML into the behaviors' policies.

Every rule was read from bigshot 5.16 and ecleanse 2.3.6 with the line
references written into `docs/hunting-engine-plan.md`, one section per
step of the build. When the engine and bigshot disagree, that document
says which line of bigshot the engine is following and why.

## Tests

The engine loads outside Lich, so the specs run without a game:

```
bundle install
bundle exec rspec
bundle exec rubocop
```

Each spec fakes the world with plain structs and stubs the send seams, so
a test says what the game answered and checks what the engine sent.

## What is not there yet

The bounty half of group hunting: each member's bounty state, the
group's verdict (a lost member before a complete bounty), and the
acknowledged shutdown with its deadline. That is the bounty objective
milestone. A routine word outside the table is sent bare, as bigshot
sends it.

## In-game runs so far

Solo on a Ranger profile, 2026-09-10: the routine language, hides and
fires, coup de grace with its health and Empowered gates, Assume Aspect
from the signs box, rests to the resting room and back, and the go2
supervision. Bandit mode, Ranger tracking and group hunting have not had
a live run yet.
