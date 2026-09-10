# Getting started

eohunter hunts with a bigshot profile you already have. This page gets
you from nothing to a dry run and then a first hunt.

## What you need

- Lich 5.20.1 or 5.21.0 with the open lich-5 pull requests the engine
  consumes. Until they merge upstream, that is the eohunter test package
  at https://github.com/Nisugi/lich-5/releases: the lib files with the
  PRs applied, the script, and an effect list. See
  [Core dependencies](core-dependencies.md) for what each PR provides.
  The script checks for the constants it needs at startup and refuses
  to start without them, naming the package.
- A bigshot profile at `data/<game>/<char>/bigshot_profiles/<name>.yaml`,
  written by bsprofiles or by hand. eohunter reads it unchanged; see
  [Profiles](profiles.md) for every key it honours.
- For Cleanse, an `ecleanse.yaml` in the same character directory,
  written by ecleanse's setup window. Without one, Cleanse runs with
  every toggle off.

## Installing

From the test package: close Lich, back up `lib/`, `scripts/eohunter*`
and `data/effect-list.xml`, unzip the archive over the Lich root, start
Lich. The package README has the revert steps.

From a build: the repo builds one `eohunter.lic` with the engine inlined
(see the README section on building). Drop it into `scripts/`. If a
`scripts/eohunter/` directory from an earlier install is beside it,
remove that directory; the built file does not read it.

## The first run

Start with a dry run. It loads the profile, resolves rooms, builds
every policy and prints them, then exits without sending a command:

```
;eohunter <profile> dry
```

Read the report. Rooms that failed to resolve, an empty routine, a
target list with no letters, a stance word the game will refuse: these
show here rather than in the hunting area.

Then hunt:

```
;eohunter <profile>
```

The script prints an `eohunter:` line for everything it decides: the
behavior that took control, the target and routine, a rest reason, a
flee reason, a cleanse. Watching those lines for one cycle tells you
whether the profile says what you meant.

## Modes

| Command | What it does |
|---|---|
| `;eohunter <profile>` | hunt: prep, walk to the hunting room, fight, loot, rest, repeat |
| `;eohunter <profile> dry` | load and report only |
| `;eohunter <profile> bandits` | bandit mode: the bandit nouns on the quick routine, no target switch, no flee past `always_flee_from`; also on when the bounty says "suppress bandit activity" |
| `;eohunter <profile> track <creature>` | Rangers: TRACK toward the creature before each step |
| `;eohunter <profile> head <count>` | lead a group: wait for that many followers, then hunt |
| `;eohunter <profile> head <name> ...` | lead a group of those characters |
| `;eohunter <profile> tail [uri]` | follow a leader; the rally whisper names the uri |
| `;eohunter bounty [<creature>]` | ebounty's hunt child, in place of `bigshot bounty` |

Group hunting is described in the README. Bounties stay ebounty's; the
bounty child reads the profile ebounty loaded and exits at the resting
room for ebounty to carry on.

## Stopping

`;kill eohunter` at any time. A trip in flight (go2) is killed with it.
`;pause eohunter` freezes the script where it is, as with any Lich
script; a trip in flight keeps walking until the next tick after
`;unpause`.

The engine also stops itself. Five failed actions in a row, or one
behavior acting more often than roundtime allows (sixty times in a
minute), trip the watchdog: it prints `watchdog:` with the behavior and
which behaviors above it declined that tick, then stops. Death stops
it unless the profile says to depart or quit. A dead player in the room
during the hunt stops it when `deader` is on. Each of these is a
decision the engine would rather hand to you than guess at; see
[Troubleshooting](troubleshooting.md) for what to look at.

## What to expect on the first hunt

One action per tick, about four ticks a second, and only the most
urgent behavior acts. In practice: Wander steps and hides, Engage takes
one routine line per tick with the roundtime waits inside the action,
Loot searches each corpse once, Maintain keeps signs and blesses up
between fights, Rest walks home when the profile's rest rule says so.
Cleanse and Flee and Survival sit above all of that and take the tick
when something is wrong.

Nothing sends a command and hopes. Every send waits for the game's
answer and returns a result, and a refused command is a failed action,
not a retry loop.
