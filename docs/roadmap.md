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
| M4 bounty objective | not started | ebounty's cycle inside the engine, solo then group |
| M5 cutover | not started | bsprofiles "Run with eohunter", ebounty setting, ecleanse alias |

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
| `movement autosneak on/off` (pre_hunt 7311, rest 7470) | gap | | small: two commands in Rest's phases |
| Stance Perfection (`cman stance N`, change_stance 6905-6921) | gap | | check what #1578's Stance does with a number first |
| Interaction monitor (`monitor_interaction` 6812) | gap | | a GTK alert on watched lines; a Watch rule plus a message would do |
| `hide_for_ammo` | gap | | read the setting, hide before recovering ammo |

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

## M4 bounty objective: what it needs

From the split plan's phases 3 and 4, on the engine:

- Each member's bounty state in its Report (`:none`, `:hunting`, `:complete`, `:failed`)
- The roster verdict on the leader: a lost member ends the hunt before a
  complete bounty; failed members keep assisting
- The acknowledged shutdown: `hunt_over` with a fifteen-second deadline,
  the exit record naming who never acked; an unclean exit holds the town run
- `Objective::Bounty`: get task, travel out, hunt (the engine as it is), travel
  back, turn in, sell, regroup; solo first, then followers for the town phases
- The nine failure cases as live acceptance: follower disconnects mid-hunt
  and after completing; leader completes while a follower is mid-swing;
  leader killed with the server dying and surviving; a follower that never
  acks; a stale hunt_over; two hunts on one group; a barrier timeout naming
  the missing member; a profile opened without being applied

## Core consumption (the review criterion)

Where the engine still carries what Lich has or should have:

- actions.rb's send ladder against `Lich::Util.issue_command` and `fput`:
  list the differences (the "wait N" sleep, the resend on a refusal), PR them,
  delete the ladder
- world.rb: every method that computes rather than delegates moves to the
  core module that owns the state
- routines.rb: spell and PSM handling that `Spell` and the PSM readers already do
- Watch rules that duplicate effect-list or Combat::Observers patterns

The group decides what goes into core; the engine keeps consuming as it lands.

## Order of work

1. Live runs: bandit mode, Ranger tracking, the final loot at rest, fog return,
   a preempted trip, then the two-character group run above.
2. The three small M1 gaps (autosneak, Stance Perfection check, hide_for_ammo);
   the interaction monitor last.
3. M4, solo bounty first.
4. Core consumption PRs as the group asks for them.
5. M5 cutover once M4 has run live with ebounty's profiles.
