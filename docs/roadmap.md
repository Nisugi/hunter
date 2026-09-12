# eohunter roadmap (2026-09-10)

What is built, what has run in the game, and what is left, in one place.
hunting-engine-plan.md has the rules and bigshot line references per step;
this file is the status board. Update it when a milestone lands or a live
run confirms something.

Status words: **built** means specs pass outside Lich; **live** means seen
working in a real hunt; **gap** means not written yet.

## Milestones

| Milestone | Status | What it is |
|---|---|---|
| P1 lich-5 helpers | in review | #1578 Stance, #1579 Stash wield/hands |
| L1 libeo | done, shrinking | only the Fog stand-in remains; goes away when #1584 merges |
| P2 parser seam | not started | widen Combat::Observers; the engine's Watch does the job for now |
| M0 spike | done, live | hunt-rest-hunt on a real profile |
| M1 solo parity | built, partly live | the checklist below |
| L3 libeosettings | not started | Setup scaffold for the e-scripts; independent of eohunter |
| M3 group | built, not live | head and tail, every follower wait, the looter, orders over DRb |
| M4 bounty child | built, not live | `;eohunter bounty` in place of `bigshot bounty`; the group verdict and acknowledged shutdown; ebounty stays the driver and gets the group changes |
| A1 LAB controller | built, not live | bounded profile-routine trials with native safe return and evidence |
| M5 cutover | not started | bsprofiles "Run with eohunter", ebounty setting, ecleanse alias |
| Corpse recovery | gap, designed | a dead group member: re-group, fog or drag home, dragger by strength; two unknowns below |

## Lich pull requests the engine leans on

| PR | What | Engine use |
|---|---|---|
| #1578 Stance | `Lich::Gemstone::Stance.change` | every stance drop |
| #1579 Stash | `wield`, `hands` | recover, wield, store routine words |
| #1580 Mana.pulse | mana pulse | Cleanse rally, spell gates |
| #1581 Bank | silver notes | (ebounty, M4) |
| #1583 PSM readers | `CMan.command`, `results_regex` | maneuvers.rb |
| #1584 Fog | `Lich::Gemstone::Fog.return` | Rest's fog phase; libeo stands in until merged |
| #1585 spell refresh | a start message refreshes an active spell | Briar Betrayer timing, every refreshable buff |

Still to open: the scripts-repo effect-list change marking 9105 `span='refreshable'`
(edited locally only).

## M1 checklist: built and live

| Item | Built | Live | Notes |
|---|---|---|---|
| Send ladder, roundtime, confirmations (`bs_put`) | yes | yes | actions.rb; candidate for a core PR (Doug's point) |
| Routine language, modifiers, once registry, repeatdelay | yes | yes | engage.rb |
| Coup de grace gates, `empowered<N>`, `thp<N>` | yes | yes | |
| Cast taxonomy, caststop, resonance rotation, mana pulse | yes | partly | resonance not seen live |
| Mstrike ladder and quickstrike | yes | no | maneuvers.rb |
| UAC tiers, smite, followups | yes | no | routines.rb |
| Wands, wandolier, recover, dislodge | yes | no | routines.rb; `hide_for_ammo` setting not read |
| Ambush and archery aiming | yes | yes | |
| Weapon reaction | yes | no | |
| Assume Aspect from the signs box | yes | yes | |
| Signs, bless, 902/411, wrack | yes | partly | bless not seen live |
| Targets: invalid, appendages, decoys, boons, priority, lone targets | yes | yes | boon ASSESS not seen live |
| Flee: message, hazards, always_flee_from, boons, crowd, ambusher | yes | partly | only the crowd rule seen live |
| Escape rooms: Belly, Ooze, Duskruin, Temporal Rift | yes | no | needs a provoked run |
| Rest reasons: wounded, fried/overkill/LTE, encumbered, dreads, thorns, confusion, oom | yes | partly | wounded and mana seen live |
| Rest cycle, waypoints, resting room, prep, scripts, rally, hunting room | yes | yes | |
| Fog return 1-5, custom fog, fog_optional, fog_rift | yes | no | |
| Loot: script, LOOT #id, delay, final, box in hand, stance, disks | yes | partly | final loot at rest not seen live |
| Deader, pull, stand, depart switch, dead man switch | yes | partly | stand seen live |
| Bandit mode and Ranger tracking | yes | no | |
| Troubadour's Rally, self and group | yes | partly | self seen live after #1585 |
| Cleanse: ecleanse's twelve conditions | yes | partly | disarm recovery and stun seen live |
| go2 supervision, suspension on preemption | yes | yes | mid-trip preemption not seen live |
| Sneaky hunting: hide before moving | yes | no | |
| `movement autosneak on/off` (pre_hunt 7311, rest 7470, 3374) | yes | no | Rest's leave and finish, the script's before_dying |
| Stance Perfection (`cman stance N`, change_stance 6905-6921) | via #1578 | no | `Stance.change` takes the number and uses the cman when trained; the engine passes the profile's stance through |
| Interaction monitor (`monitor_interaction` 6812) | gap | | a GTK alert on watched lines; a Watch rule plus a message would do |
| `hide_for_ammo` | n/a | | bigshot reads the setting and never uses it (only the accessor at 2724) |

## M3 group: built and live

| Item | Built | Live |
|---|---|---|
| Hub over DRb, register, orders, reports, liveness | yes | no |
| head: group open, rally whisper, readiness barrier, timeout | yes | no |
| tail: rally watch, connect, register, wait for activation | yes | no |
| Leader waits: looting done, gathers, quiet followers, rested, sneaky | yes | no |
| Independent travel and return | yes | no |
| Looter choice, loot handed to a follower, follower_overkill | yes | no |
| Attack orders, call a missing follower back, disable_commands | yes | no |
| Muster: stunned member, missing follower between fights | yes | no |
| Follower: Orders, Assist, Follow, Loot on assignment | yes | no |
| Lost follower reported and skipped; lost leader stops the follower | yes | no |
| Group deader; rally for a stunned member | yes | no |

First live run: two characters, one area, `head 1` and `tail`, a full
hunt-rest-hunt cycle. Then kill the follower's Lich mid-hunt (leader keeps
going, reports the loss) and kill the leader's script mid-hunt (follower
stops with hunt_over or leader_lost, no walk to the rest room).

## M4 bounty child: built and what is left

ebounty is not absorbed. It stays the driver for every bounty type and runs
eohunter as the hunt child where it ran bigshot. Built:

| Item | Built | Live |
|---|---|---|
| `;eohunter bounty [<creature>]`: profile from UserVars.op, bounty_eval, bandits from the bounty | yes | no |
| Forced rest on completion; exit at the resting room once prepped (`:rested`) | yes | no |
| Child rescue exit | yes | no |
| Each member's bounty state in its report | yes | no |
| Leader verdict: a lost member before a complete bounty; the done keep assisting | yes | no |
| Acknowledged shutdown with a fifteen-second deadline and the unacked list | yes | no |

### What ebounty needs (its own change, not the engine's)

1. **A hunter setting.** `hunting_script: bigshot | eohunter`. Where `go_hunting`
   runs `bigshot bounty` (2288) and `bigshot bounty <creature>` (2286), run
   `eohunter bounty` and `eohunter bounty <creature>`; `keep_hunting` (2069)
   runs `eohunter <default profile>` once instead of `bigshot single`; the
   `before_dying` kill (3652) and the required-scripts check (3675) name
   whichever is set. Everything else in `go_hunting` stays: the child reads
   `UserVars.op` and `bounty_eval` as it is written today.
2. **The child's exit reason.** eohunter stops with `:bounty_rest` (done and
   rested), `:child_rescue`, `:member_lost`, `:leader_lost`, `:hunt_over`,
   `:dead`, or `:script_killed`. ebounty needs to read it after the child
   dies (a `UserVars` key or a `Script` return value, to be decided) and
   treat `:member_lost` and an unclean shutdown as "do not start the town
   run".
3. **Group bounties.** The leader's ebounty starts `eohunter bounty head <count>`;
   each follower's ebounty starts `eohunter bounty tail`. Each member keeps
   its own task and count. The town phases on a follower (trail the
   leader, turn in, get the next task, sell, report ready) are a new
   follower mode in ebounty; the engine's Hub can carry those signals
   between the two ebounties if wanted, or LNet can.
4. **The bandit flag.** `over_watch` (431) sets `$bigshot_bandits` only while
   bigshot is running; eohunter sets it itself from the bounty text, so
   the thread should check for either child or be dropped.
- The nine failure cases as live acceptance: follower disconnects mid-hunt
  and after completing; leader completes while a follower is mid-swing;
  leader killed with the server dying and surviving; a follower that never
  acks; a stale hunt_over; two hunts on one group; a barrier timeout naming
  the missing member; a profile opened without being applied

`scripts/eohunter/objective.rb` is a withdrawn in-engine bounty cycle, kept
but not loaded. Do not extend it.

## Core consumption (the review criterion)

The audit is `core-consumption-audit.md`. Status:

- actions.rb's send ladder is fput's (lich-5 #1587, open); settle_rt is
  waitrt? / waitcastrt?
- world.rb: the Forge leftovers are gone (4edaf6c); what is left delegates
- cleanse helpers: Mana.pulse, settle_rt, Actions::Stand (4edaf6c)
- Watch rules: watch.rb subscribes to Combat::Messages, :ucs and :attack
  (lich-5 #1586, open); the only rule left is the profile's flee text
- the libeo stand-in is gone; Fog is Lich's (#1584)
- routines.rb: two Stash candidates (store a hand, put into a named
  container) not yet opened

The engine therefore runs only on a Lich with the nine PRs: the eohunter
test package (github.com/Nisugi/lich-5/releases) until they merge. The
script refuses to start on a Lich without them and says so.

## Corpse recovery: a group member dies (gap, designed not built)

Today a dead group member is announced and the leader stops: Survival's
`deader` emits `:deader` and returns `:deader`, and the `group_deader`
toggle decides whether it fires at all. Nothing recovers the body. bigshot
has no precedent here either - its only DRAG is `_drag` moving a weapon
into a container - so this is new behaviour rather than a parity gap, and
it needs its own design pass rather than an inferred implementation.

The intent, in order:

1. **Re-group them.** Death drops the character from the game's group, so
   the leader re-invites before anything else.
2. **Fog out if fog is configured.** Grab the body first, then fog, so the
   trip home carries them.
3. **Otherwise drag.** `drag #<id>` by id, not noun - two members can share
   a noun, and the pre-movement pull in bigshot uses the id form for the
   same reason. A hand must be empty before the drag will take.
4. **Handle too heavy.** The game refuses a corpse that outweighs the
   dragger; on that refusal, `drag stop` rather than retrying.
5. **Then branch on the room.** Dangerous: leave, and accept the body stays.
   Safe: hold there until it stops being safe, so the group is not split.
6. **Choose the dragger.** The highest strength bonus in the group, or a
   configured member when one is named and available.

### What has to be decided before this is written

- **The refusal text.** The gate for "too heavy" needs the game's actual
  line. A guessed regex gives a branch that silently never fires, which is
  worse than no branch at all. This has to come from a real log.
- **What "dangerous" means.** Any hostile creature present, the flee
  predicate, or something narrower. The room-safety branch is the whole
  difference between leaving a body and stranding the group.
- **Who decides the dragger.** Highest strength bonus means each follower
  reports its bonus, which is a new `Report` field and so a protocol
  change; the alternative is the leader assigning by configured name only.
  `Stats` is already reachable through World, so either is buildable.

### What already exists to build on

`Fog.return` (Rest::Fog), the hand-emptiness readers (`Hands#empty?`,
`#right_empty?`), `Stats` through World, the group's DRb order channel,
and Survival's existing dead-member detection. The pieces are all there;
the sequencing and the two unknowns above are the work.

## Order of work

1. Live runs on the test package: bandit mode, Ranger tracking, the final
   loot at rest, fog return, a preempted trip, autosneak, then the
   two-character group run above.
2. A live bounty through ebounty with eohunter as the child, once ebounty can start it.
3. M5 cutover once the bounty child has run live with ebounty's profiles.
