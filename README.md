# eohunter

A hunting script for Gemstone IV on Lich 5, built as an engine of small
behaviors rather than one long loop. It reads bigshot profiles unchanged,
so an existing profile runs here without edits, and it folds ecleanse in
as one of its behaviors.

## Running it

```
;eohunter <profile>        hunt with data/<game>/<char>/bigshot_profiles/<profile>.yaml
;eohunter <profile> dry    load the profile, report the policies, do not run
```

`scripts/eohunter.lic` needs `scripts/libeo.lic` (go2, fog return, the
version gate) alongside it, and Lich 5.22 or newer with the PSM reader
methods from lich-5 #1583 (`CMan.command`, `CMan.results_regex` and their
siblings). Cleanse reads `data/<game>/<char>/ecleanse.yaml`, which
ecleanse's own setup window writes.

## How it works

Each tick, about four times a second, the engine asks every behavior in
priority order whether it wants control, and the most urgent one gets to
run one action. An action is a game command with its preconditions, its
roundtime wait, its send through bigshot's refusal ladder, and its
confirmation on the game's answer, returning a result the caller must
handle. Nothing sends a command and hopes.

| Priority | Behavior | From bigshot / ecleanse |
|---|---|---|
| 0 | Survival | dead, escape rooms, stand, pull, dead players |
| 5 | Cleanse | all of ecleanse: afflictions, hazards, disarm recovery, hive traps |
| 10 | Flee | `should_flee?` and the ambusher, one step out per tick |
| 20 | Rest | `ready_to_rest?`, the rest cycle, `ready_to_hunt?` |
| 30 | Loot | `need_to_loot?`, the loot script, the fried bookkeeping |
| 40 | Maintain | signs, bless, wrack |
| 50 | Engage | the routine language, one line per tick, every command check |
| 60 | Wander | the hunting area, the claim, one step per tick |

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
- `watch.rb`: the one DownstreamHook, a rule table from line to event.
- `travel.rb`: the go2 script supervised a tick at a time.
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

Group hunting and followers (bigshot's MA), bandit and Ranger tracking,
the 1040 and Troubadour rallies, and the Assume Aspect entry in the signs
box. A routine word outside the table is sent bare, as bigshot sends it.
