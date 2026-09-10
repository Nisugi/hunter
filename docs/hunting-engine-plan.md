# eohunter, libeo, and lich-5: plan (rev 3)

For: horibu, Tysong, therealatari
From: Nisugi

Status: replaces the bigshot split (bigshot-ma-refactor.md, bigshot-ma-implementation.md); those
stay as reference for the MA protocol and the bigshot inventory. Companion:
eo-shared-lib-analysis.md (the overlap measurements this rev is built on).

## Decision

Three moves, built in this order:

1. **Two lich-5 PRs.** The parts of the shared skeleton that are game rules or parser
   infrastructure go into Lich itself, where they version with Lich and benefit every script
   including bigshot: a stance setter and a wield / two-hand reconciler beside `Lich::Stash`
   (most of the rest of the skeleton turned out to already be in lib, see the audit); and
   a general parser event seam built by widening `Combat::Observers` beyond combat, with
   subscription-gated pattern families and the non-combat message defs.
2. **libeo**, a shared library for the e-scripts, for what is script-side: the go2 wrapper,
   silver and bank notes, fog return, escort, the settings scaffold, and the control model copied
   from Forge (tick engine, priority arbiter, verified actions, behaviors, area movement,
   recorder, group service) sitting on the lich seam. Existing scripts adopt the small helpers
   one call site at a time; nothing has to move at once.
3. **eohunter**, the hunting engine we want for the next five years, built on libeo's engine
   layer. It consumes bigshot profiles unchanged, compiles bigshot's routine language into
   verified actions, ports bigshot's edge cases against a checklist, absorbs ecleanse as a
   behavior, and later absorbs ebounty's cycle as objectives in the same process.

bigshot, horibu's 5.16 stack, and #2456 are untouched throughout. Forge is the reference for the
control model, not a dependency; its core is copied into libeo and allowed to diverge.

## Why a library first

The overlap analysis found about 2,500 lines of the same jobs done five slightly different ways
across ebounty, eloot, eherbs, ecleanse, and bigshot: send-and-await with roundtime retry, wait
for RT, change stance, wrap go2, message, version, silver and bank notes, hands and containers,
mana pulse, escort, fog return. Each copy fixed a problem the others still have. eohunter needs
every one of those helpers on day one. Writing them once, as a library the other scripts can pick
up, costs a week and means the engine and the children it runs (eloot, eherbs, go2) agree on what
"send this and wait for that" means. Today they don't.

The same argument applies one layer up. Verified actions, behaviors, and the world facade are
what eohunter is made of, and they are what eloot's `Loot` module or eherbs' stocking loop would
be made of if anyone rewrote them. Putting that layer in the library doesn't obligate anyone to
rewrite anything. It means the option exists.

## Why some of it goes into lich-5 instead

Two thirds of the util layer is game rules or parser plumbing, not script convenience, and Lich
already has the half-finished version of each:

- `Lich::Util.issue_command` already retries after roundtime: it sends through `fput`, which
  re-sends on `...wait N`, waits out stun and web, and stands first when told to. The e-script
  wrappers exist because they bypass `fput`. No `retry_rt:` option is needed; the five wrappers
  delete themselves by calling `issue_command` as it is.
- `waitrt?` / `waitcastrt?` / `checkrt` are the `wait_rt` variants. `XMLData.last_pulse` with
  `noded_pulse` / `unnoded_pulse` is mana pulse. `Spell#affordable?`, `#known?`, `#available?`
  and `PSMS.available?` are able_to_cast. `Script.version(name, required)` and
  `Script.require_lich_version!` are the version checks.
- Hands: `Lich::Stash` (stash_hands, equip_hands, find_container, add_to_bag, sheath-aware via
  `ReadyList` / `StowList`) and `Lich::Common::Inventory` (nested container tree, `closed?`,
  `space_left`) already cover eherbs' containers, and `Stash.container` opens a closed one.
  What was missing is small: `wield` by name, id, or ready slot, and a two-hand reconciler
  (Forge's PrepareHands). Both drafted 2026-09-09 as `Stash.wield` / `Stash.hands`.
- Stance is the one genuinely missing module. `Char.stance` reads it; nothing sets it except the
  private sequence inside `Spell#cast`.
- Messaging, status (`Status.muckled?` and friends), silver (`Currency.silver`,
  `Util.silver_count`), account type for f2p (`Account.type`), group (`Group.members`,
  `leader?`, `nonmembers`, `broken?`), bounty (`Bounty.current` → `Task` with predicates),
  creature flags (`CreatureTemplate#sleepable?` / `muggable?`), room claim (`Lich::Claim`),
  tag lookup (`Map.rooms_by_tag`, `Room#find_nearest_by_tag`) all exist. The full audit is in
  eo-shared-lib-analysis.md.
- `Combat::Observers` is already a subscription seam fed by the combat processor, and Creature
  and Combat::Tracker are the state model. Forge's own event bus and world facade exist because
  that seam is combat-only. Widening it is the lich-side move that makes libeo's World and
  Patterns thin.

What stays script-side: silver and bank notes, fog return, escort, the go2 wrapper (they encode
town knowledge or depend on other scripts); the Gtk settings scaffold (Gtk is the layer the
WebUI branch is replacing, so it must stay swappable without a Lich release); and the engine
itself (opinionated, and a Lich release per engine change would slow eohunter by months; if it
proves itself for a year and a second script wants it, that's when it earns a place in lib).

### Performance of the parser seam

The seam costs nothing per line by itself; the parsing that feeds it is the cost, and it's
already paid on every line for anyone running bigshot 5.16, which enables the tracker
persistently per character. Widening the seam adds regexes, so the PR must carry three
properties, all already available in the combat code:

1. Each pattern family is scanned only when something has subscribed to it (`any_for?`). No
   hunting script running means one literal scan per line and nothing else.
2. Literal pre-gates on every family, which the def loader derives automatically (measured: about
   7 microseconds per line gated, 0.5 to 1 ms ungated).
3. All matching stays on the tracker's async worker, never the parser thread.

That is strictly cheaper than today, where bigshot, ecleanse, eloot and Forge each install their
own downstream hook and run their own regexes inline on the parser thread, unshared. The one
thing to raise with horibu alongside the PR: the tracker's persistent enable is what makes it
always-on; session-scoped enable with disable-on-last-subscriber would make it pay-only-when-used.

## libeo: layers and files

`Script.loadlib` (lich-5, Calael) requires the `lib` prefix. Three files, each loadable alone,
each depending only on the one below it, all sitting on the two lich-5 PRs:

| Where | Layer | Contents | Consumers |
|---|---|---|---|
| lich-5 PR 1 | lib helpers (small) | `Lich::Gemstone::Stance.change(name, force:)` (bigshot's, with perfect stance; reuses the regex `Spell#cast` already carries); `Lich::Stash.find_item`, `.wield(item, hand:)`, `.hands(right:, left:)` beside stash_hands / equip_hands (Forge's reconciliation). Everything else the util layer needs is already in lib (see the audit) | every script, including bigshot |
| lich-5 PR 2 | parser seam | `Combat::Observers` widened to a general parser event seam with subscription-gated families; non-combat defs (roundtime rejected, referent missing, weapon missing, out of reach, hazards forming, swept, falling, stand blocked, and ecleanse's twelve conditions) in `lib/gemstone/combat/defs` or a sibling; bigshot's `cmd_*` result regexes | libeoengine, Forge, any script that wants events instead of its own hook |
| libeo.lic | util | `EO.go2(place, kill_running:)`, `EO::Silver` (check, deposit, withdraw, bank notes, f2p; eloot's), `EO::Fog` (bigshot's family), `EO.escort` (eherbs'), `EO.deader?`, `EO.msg` / `EO.help` shims over `Lich::Messaging`, and forwarding shims for the PR 1 helpers until they ship | every e-script, immediately, per call site |
| libeosettings.lic | settings | `EO::Settings::Data` (load, defaults, profile load/save, coerce, normalize; backed by UserVars, CharSettings, or a YAML profile dir), `EO::Settings::Setup < Gtk::Builder` (the scaffold identical in all five: get_category, get_setting, update_setting, load_settings, on_update, on_close, on_destroy, start, list, tooltips, profile drop-down), with a file-only mode so any script gets an isolated editor the way bsprofiles gave bigshot one | any e-script that keeps a Setup; bsprofiles; eohunter has none until M5 |
| libeoengine.lic | engine | copied from Forge and adapted, namespace `EO::Engine`: `Events` (await and during over the lich seam; own bus only for engine-internal events), `World` (Me, RoomView, Hands, creature_state, routes, unreachable rooms; thin over Creature and XMLData), `Actions` (Base contract: preconditions, settle RT, target-still-live, perform; Attack, Cast, Maneuver, MultiStrike, Hide, Unhide, Stand, Stance, PrepareHands, Loadout, Move, Travel, Teleport, RunScript, Command), `Patterns` reduced to subscriptions on the lich seam, `Engine` (tick, priority arbiter, watchdog, pause, stop), `Behavior`, `Movement::Area`, `Recorder`, `Survival`, `Group` (the MA service) | eohunter; later any script that wants verified actions or a behavior loop |

Rules that hold across all three:

- Each file carries a Lich version gate and `EO::VERSION`; a script names the version it was
  built against and the library refuses a mismatch loudly. Same discipline the split planned.
- util does not depend on engine. `issue_command` is line-capture, which is what
  the existing scripts do; `Actions::Base` is event-driven over the lich seam. They are different
  mechanisms on purpose: line-capture is the migration path, actions are the destination, and a
  script can be on either.
- Until PR 1 ships, libeo carries forwarding shims with the final names, so scripts can migrate
  call sites now and the shims become one-line delegations later.
- Nothing script-specific goes in. eloot's Loot, Sell, Hoard; ebounty's Task; eherbs' stocking;
  ecleanse's recovery actions stay in their scripts (or, for ecleanse, move into eohunter).
- libeo lives in the EO scripts repo like any script, so it ships through the same updater.
  Forge may or may not adopt it later; that's Forge's problem, not this plan's.

## eohunter on top

`;eohunter <profile>`, namespace `EOHunter`. One process, one engine, behaviors in priority
order; lower number wins the tick. Behaviors hold no positional state, intent is re-derived from
World every tick, which is what makes pause, stop, and cancellation free: `stop!` sets a flag,
the current action finishes inside its own bounded timeout, and no behavior gets another tick.

| Priority | Behavior | From | Wants control when |
|---|---|---|---|
| 0 | Survival | libeoengine | dead, muckled, prone, hazard, lost item, out of mana in a trap, needs healing |
| 5 | Cleanse | ecleanse | poison, disease, stun, web-bound, weapon lost or webbed, hive trap, itchy curse, infected wound, sanctum transform; one verified recovery action per tick |
| 10 | Flee | bigshot | `always_flee_from`, boon flee list, clouds / vines / webs / voids, ambusher, `flee_count` exceeded, swallowed, rift tumble |
| 20 | Rest | bigshot | any `should_rest?` condition; then drives: prepare for movement, fog or walk to resting room, resting commands and scripts, wait for `rest_till_*`, hunting prep, walk back |
| 30 | Loot | bigshot | dead things, claim held, no live valid target (or `delay_loot`), not wounded, followers done; runs eloot as a supervised child; never / random / final loot, box in hand, disks |
| 40 | Maintain | bigshot | signs due, bless, prep buffs down, weapon reaction, wand and ammo state |
| 50 | Engage | new | a valid target is present; executes the compiled routine for it |
| 50 | Assist | new | follower mode: the leader's target, or any valid target once the leader has engaged |
| 60 | Wander | bigshot + Area | no target, inside the hunting area: LRU wander within boundaries, `wander_wait`, wander stance, sneaky, rally rooms; boundary break stops the run |
| 70 | Objective | new | what the run is for: `Hunt` (forever or `single`), `Bounty`, `Town`, `Regroup`, `Watch` (for `;eohunter cleanse`) |

eohunter's own code is therefore: the profile loader (bigshot YAML in, via bsprofiles), the
routine compiler, nine behaviors, the verb-specific actions bigshot has and Forge doesn't (wand,
wandolier, jewel, throw, sacrifice, tether, briar, fire, ambush, unarmed, smite, and the maneuver
families), the objectives, and a CLI. Everything else is libeo.

### Patterns to lib combat defs

bigshot's `cmd_*` bodies carry the result messaging for every verb, roughly 300 regexes. Those
move into `lib/gemstone/combat/defs` in lich-5 as part of PR 2, so the seam emits them and
libeoengine, Forge, and bigshot itself can all derive from one catalogue.

## Profile compatibility

eohunter reads the same YAML bsprofiles writes. All 103 keys are honoured or explicitly retired;
nothing is silently ignored.

| Profile group | Keys | Consumer |
|---|---|---|
| Resting: where | `return_waypoint_ids`, `resting_room_id`, `resting_commands`, `resting_scripts`, `fog_return`, `custom_fog`, `fog_optional`, `fog_rift` | Rest |
| Resting: when | `fried`, `overkill`, `lte_boost`, `oom`, `encumbered`, `wounded_eval`, `creeping_dread`, `crushing_dread`, `wot_poison`, `confusion`, `box_in_hand` | Rest predicates |
| Hunting map | `hunting_room_id`, `rallypoint_room_ids`, `hunting_boundaries` | Wander (Area) |
| Hunting: when | `rest_till_exp`, `rest_till_mana`, `rest_till_spirit`, `rest_till_percentstamina` | Rest exit predicates |
| Hunting: how | `hunting_stance`, `wander_stance`, `stand_stance`, `hunting_prep_commands`, `hunting_scripts`, `signs`, `loot_script`, `wracking_spirit`, `use_wracking` | Maintain, Engage, Loot |
| Toggles | `priority`, `delay_loot`, `troubadours_rally`, `loot_stance`, `pull`, `deader`, `sneaky_sneaky`, `check_favor`, `bless`, `lone_targets_only`, `weapon_reaction`, `tier3` | Engage, Loot, Maintain, Wander |
| Flee | `flee_count`, `invalid_targets`, `always_flee_from`, `flee_message`, `boon_flee_from`, `flee_clouds`, `flee_vines`, `flee_webs`, `flee_voids` | Flee, Engage |
| Attacking | `ambush`, `archery_aim`, `aim`, `wander_wait` | Engage, Wander |
| Commands | `hunting_commands` and `_b` through `_j`, `targets`, `quickhunt_targets`, `quick_commands`, `disable_commands` | Engage (routine compiler) |
| UAC, mstrike | `uac_smite`, `uac_mstrike`, `mstrike_*` | Engage verbs |
| Ammo, wands | `ammo_container`, `ammo`, `fresh_wand_container`, `dead_wand_container`, `wand`, `hide_for_ammo`, `wand_if_oom` | Maintain |
| MA | `independent_travel`, `independent_return`, `group_deader`, `ma_looter`, `never_loot`, `random_loot`, `final_loot`, `quiet_followers`, `ignore_disks` | Loot, Wander, Assist |
| Monitoring | `dead_man_switch`, `depart_switch`, `monitor_interaction`, `monitor_strings`, `monitor_safe_strings` | Survival policy, a Watcher subscriber on the bus |
| Internal | `bounty_eval` | Bounty objective; honoured as an eval string for existing ebounty-written profiles, replaced by per-task predicates in M4 |
| Cleanse (new group) | ecleanse's spell choices and avoidance toggles | Cleanse |

Retired: none in M1. Candidates after M4, with a warning when set: `bounty_eval` (once ebounty
stops writing it), `quickhunt_targets` and `quick_commands` (Quick is #2456's domain in bigshot;
eohunter's equivalent is the `Hunt` objective with `single`).

## The routine language

bigshot's real asset. A routine is a list of command strings; each has a verb, optional
arguments, and modifiers that gate it. eohunter compiles a routine once per profile load:

```
"cman bullrush !stunned prone"      -> Maneuver(bullrush)   guarded by [not stunned, prone]
"incant 1030 thp<50> !EB"            -> Cast(1030)           guarded by [target hp <= 50, no evanescent barrier]
"mstrike"                            -> MultiStrike          guarded by [stamina ladder from mstrike_* keys]
"wand"                               -> Wand                 guarded by [wand state]
"script foo bar"                     -> RunScript(foo, bar)
"sleep 2"                            -> Wait(2)
"eachtarget fire"                    -> Fire, repeated over valid targets
"force attack"                       -> Attack               with stance dance forced
```

| bigshot verb | Action | In libeoengine already |
|---|---|---|
| attack, k, fire, ambush, unarmed, smite | Attack (verb variants; UAC tiers as preconditions) | Attack yes; variants new |
| incant, resonance, caststop, `<spell number>` | Cast, with bigshot's self-cast / blocked / hindrance taxonomy as result reasons | Cast yes; taxonomy to port |
| cman, feat, shield, warcry, bullrush, chastise, bearhug, cutthroat, shout, stomp, leech, rapid, depress, phase, curse, efury, dhurl, assume, burst, surge, berserk | Maneuver, one subclass per family where the confirmation differs | Maneuver yes; families to port |
| mstrike | MultiStrike | yes |
| hide | Hide | yes |
| wand, wandolier, jewel, throw, sacrifice, tether, briar | new actions in eohunter | no |
| wield, store, nudgeweapons | Loadout / PrepareHands | yes |
| stance | Stance | yes (new in libeoengine) |
| script, sleep, wait | RunScript, Wait | RunScript yes |
| force, eachtarget, celerity / haste / slayer / tonis prefixes | compiler directives | n/a |

Modifiers, from `check_state_condition`, each negatable with `!`: effects (`ES`, `EB`, `EC`,
`ED`, `506`, `animate`, `barrage`, `bearhug`, `burst`, `celerity`, `coupdegrace`, `flurry`,
`fury`, `garrote`, `holler`, `momentum`, `pummel`, `rapid`, `rebuke`, `scourge`, `shout`, `surge`,
`tailwind`, `thrash`, `vigor`, `voidweaver`, `yowlp`); self state (`disease`, `hidden`, `outside`,
`poison`); target state (`ancient`, `flying`, `frozen`, `noncorporeal`, `prone`, `rooted`,
`undead`, `calm`, `disoriented`, `hovering`, `immobilized`, `kneeling`, `sitting`, `sleeping`,
`stunned`, `webbed`, the #2456 classification flags, `wounded`, `fatalcrit`, `smote`, `ucs*`);
amounts (`thp<N>`, `buff<N>`, `empowered<N>`, stamina / mana / spirit thresholds). Each becomes a
precondition over World. The compiler rejects an unknown modifier at profile load instead of at
swing time, a behaviour change bigshot users will notice and, I think, welcome.

## Group and MA

The protocol from the split plan stands. `Group` lives in libeoengine because ebounty's town
phase will need it too. Built 2026-09-10 as `scripts/eohunter/group.rb`; see "Group: bigshot's
head and tail (M3)" below for what landed and what M4 still owes (bounty state, the verdict,
the acknowledged shutdown).

- `Group` (DRb, behind an interface): hunt id, expected roster, readiness barrier, per-member
  progress and liveness polled separately with liveness first, leader heartbeat and finished
  flag, acknowledged shutdown with a monotonic deadline bounding every remote call, an exit
  record that names who never acked. Every event and every ack validates the hunt id.
- The leader's engine emits hunt-scoped events (`:leader_engaged`, `:leader_moving`,
  `:leader_resting`, `:loot_assigned`, `:hunt_over` with reason). The follower's engine subscribes
  and feeds them to its own behaviors: Assist reads the leader's target, Wander the leader's
  room, Loot the looter assignment, Rest the leader's rest state.
- Followers run the same engine with Assist instead of Engage and Wander in follow mode.
  Survival, Cleanse, Flee, Maintain are the follower's own.
- Bounty completion: each member's Bounty objective reports its state; the leader's ends the
  hunt with `:bounty_complete` or `:member_lost`.

## ebounty stays ebounty (decision 2026-09-10)

This section used to propose an `Objective::Bounty` owning ebounty's cycle inside the engine.
That is withdrawn: ebounty remains its own script and the driver for every bounty type, and it
is ebounty that gets modified for group bounties. eohunter only replaces the hunt child, the way
`bigshot bounty` is a child: `;eohunter bounty` reads the profile ebounty loaded into
`UserVars.op` (targets and rooms already rewritten for the task), evaluates ebounty's
`bounty_eval` the way bigshot's `bounty_check?` does, forces a rest when it says done, and exits
at the resting room once prepped, where ebounty picks the cycle back up. See "Bounty child mode"
below. `scripts/eohunter/objective.rb` is the withdrawn objective, kept in the tree but not
loaded; do not extend it.

## Adoption path for the existing scripts

None of this is required for eohunter to ship; it's what the library makes possible.

| Script | Util layer | Settings layer | Engine layer |
|---|---|---|---|
| eloot | replace `get_command` / `get_res` / `wait_rt` / `change_stance` / silver / hands with `EO.*` as call sites are touched; eloot's versions are the superset for silver, so this is mostly deletion | Setup becomes `EO::Settings::Setup` subclass; gets an isolated editor for free | `Loot` and `Sell` as behaviors is a real option later; not planned |
| eherbs | same; eherbs' container helpers are the ones the library adopts, so this is a move not a rewrite | same | not planned |
| ebounty | same for util; the town phase is what M4 moves into eohunter | same, until M4 makes it moot | absorbed into eohunter at M4 |
| ecleanse | n/a | n/a | absorbed into eohunter at M1 as Cleanse; `;eohunter cleanse` replaces it; ecleanse.lic becomes an alias for one release |
| bigshot | could adopt util for the handful of helpers it duplicates; not proposed, since bigshot is horibu's and #2456 is in flight | | |

## Milestones

Done straight through; each has an acceptance check, used as a checkpoint when wanted.

**P1, lich-5 helpers PR (two or three days, review latency on top).** Stance module and the Stash additions (find_item, wield, hands). Opened 2026-09-09 as
lich-5 #1578 (Stance) and #1579 (Stash.wield / hands), specs green.
Acceptance: eloot and eherbs each run one real session with `get_command`, `wait_rt`, and
`change_stance` replaced by `issue_command`, `waitrt?`, and `Stance.change`, no behaviour change.

**L1, libeo.lic (three days, overlapping P1).** go2 wrapper, silver bank and notes, fog,
escort, deader, messaging shims, forwarding shims for P1. Version-gated. Most of L1 is deleting
script copies in favour of the lib calls the audit found, not writing new code.

**P2, lich-5 parser seam PR (two weeks, review latency on top).** Widen `Combat::Observers` to
a general seam with per-family subscription gating, literal pre-gates, async matching; add the
non-combat defs and bigshot's result regexes (this absorbs the old M2). Acceptance: the
tracker's existing specs pass; a new spec proves no family is scanned without a subscriber;
measured per-line cost with no subscribers is within noise of today; ecleanse's twelve
conditions replay from recorded logs as events.

**L2, libeoengine.lic (a week, after P2 is on the prerelease).** Copy Forge's core into
`EO::Engine`, rename, drop the measurement-only pieces, rebase Patterns and World onto the lich
seam, add Stance and Command actions, move Group's contract in from the split plan. Acceptance:
Forge's engine, actions, and survival specs pass against the copy; separate-file load spec (util
alone, util + engine, twice in one process, version refusal).

**M0, spike (a week).** `;eohunter <profile>` solo, one area, one routine: Survival, Rest with
walk-only return, Engage compiling `hunting_commands` for attack, incant, cman, mstrike, hide,
Wander in the profile's area. No loot, no signs, no scripts. Acceptance: a hunt-rest-hunt cycle
on a real bigshot profile, and `;eohunter stop` ending mid-swing within one action.

**M1, solo parity (four to five weeks).** Everything in the profile table except MA. Loot via
eloot, Maintain, Flee with every trigger, Cleanse with every ecleanse condition, all verbs and
modifiers, fog family, priority, deader, pull, lone targets, UAC tiers, mstrike ladder, sneaky.
`;eohunter cleanse` replaces standalone ecleanse. Acceptance: the edge-case checklist, each item
live-tested where it can be provoked and replay-tested from a recorded log where it can't.

**L3, libeosettings.lic (a week, any time after M1).** The Setup scaffold and Data. Acceptance:
eloot's Setup as a subclass with identical behaviour, plus its new isolated editor mode.

**M3, group (two weeks).** Group in use, Assist, follow-mode Wander, leader events, the full
protocol, and the nine failure cases from the split plan as acceptance.

**M4, bounty child (withdrawn as an objective, 2026-09-10).** ebounty keeps the cycle;
eohunter is its hunt child (`;eohunter bounty`), with the group's bounty state, verdict and
acknowledged shutdown. Acceptance: the 15/25 milestone from the split plan with ebounty on the
leader running eohunter children, once ebounty's group support lands.

**M5, cutover.** bsprofiles gains "Run with eohunter" next to "Apply to Bigshot". ebounty gains a
setting to use eohunter instead of bigshot. ecleanse.lic becomes the alias. eloot and eherbs
finish their util migration when convenient.

## Send and confirm: bigshot's rules (step 1 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`bs_put` 7868, `cmd` 3296, `command_check` 3539, `change_stance` 5764,
`stand` 5901, `cmd_cmans` 4092, `cmd_ranged` 5324, `cmd_spell` 4867, `cast_spell` 4830,
`cmd_burst` 5405, `wait_for_swing` 5794) and Lich's `fput` (global_defs 1643). What the engine's
Actions::Base reproduces, and where it deliberately differs.

**The send ladder (`bs_put`, which is `fput` with three differences).** Clear the buffer, send,
then read lines until one is not a refusal:

| Line | bigshot | Lich `fput` | Engine |
|---|---|---|---|
| `...wait N` / `Wait N` | sleep N-1, resend | sleep N, resend | sleep N, resend; counts as a resend |
| `struggle ... stand` | send `stand` through the ladder, resend | same | same |
| `stunned` | wait until not stunned, resend | same | same, bounded, interruptible |
| webbed (same regexes) | wait until not webbed, resend | same | same, bounded, interruptible |
| `can't do that while` / `cannot seem` / `can't seem` / `don't seem` / `type ahead` and not stunned or webbed | sleep 0.25, resend (forever) | return false (fail) | resend, bounded |
| dead | return false | return false | fail `:dead` |
| no response | wait forever | 60 s timeout | deadline, fail `:no_response` |
| anything else | return the line | return the line | return the line |

bigshot's version has no timeout and no resend cap; two of its lines (`stand`, the 0.25 s
resend) can loop indefinitely. The engine keeps every rung and adds a resend cap, a deadline,
and an interrupt check on every wait so `stop!` ends a stuck send within a tick.

**Before every command (`cmd`).** In this order: pull prone group members and pause on a
deader; escape rooms (Belly of the Beast, Ooze innards, Temporal Rift); `waitrt?` then
`waitcastrt?` (skipped for `nudgeweapons` / `slipperymind`; cast RT skipped for `hide` and
`cock`); the command's modifiers (`command_check`); prefixes (`force`, `eachtarget`,
`celerity` / `slayer` / `tonis`); `stand` if not standing; stance dance to `hunting_stance`
unless the command is a spell number, wait, sleep, wand, berserk, script, hide, nudgeweapon;
target still valid and (if `priority`) still the priority target. These are not Base's job. The
deader / escape / stand checks are Survival, the modifiers are the routine compiler, the stance
dance and target gate are Engage. Base does exactly: preconditions, settle RT, target still
live, not dead, send, confirm.

**Roundtime.** bigshot waits both RTs before everything. Forge found cast RT only blocks
casting, attacking and dropping to defensive. Base settles hard RT for every action and cast RT
only for actions that opt in (CombatRt: attack, cast, maneuver, mstrike, stance-to-defensive).
Same effect as bigshot's exceptions for hide and cock, generalised. If this ever misfires the
fix is one `include CombatRt`.

**Confirmation, three shapes, all from bigshot.**

- *Result line* (`cmd_cmans`, `cmd_ranged`, `cmd_burst`): `dothistimeout` with a short window
  (1 to 2 s), a "complete" regex naming every known answer, and a loop that on `...wait`
  waits RT and resends, on a complete line stops, and on `false` (nothing matched) sets
  `should_rest` with an "unknown result" reason. The regexes are what PSM `.results_regex`
  now returns for maneuvers. Engine: `send_and_match(command, regex, timeout:)`.
- *State change* (`stand`, `change_stance`, `cmd_wield`): send, then read `standing?`,
  `Char.stance`, `GameObj.right_hand`. Engine: `send_and_observe(command) { world... }`.
- *Event* (`wait_for_swing`, cast taxonomy): a line-watcher for "the target swung at you",
  and `Spell#cast`'s return classified into blocked (`no need for spells of war`, `Spells of
  War cannot be cast`, `Cast at what`), hindrance (retry up to 3), success. Engine:
  `send_and_await(command, *event_types)` over the bus, fed by Combat::Observers.

**Unknown result is a rest reason, not a retry.** Every `cmd_*` that gets `false` from its
window sets `$bigshot_should_rest` with the reason. The engine's equivalent is
`Result(status: :timeout, reason: :no_confirmation)`, which the failure watchdog counts.

**Target gone.** bigshot checks `npc.status =~ /dead|gone/` and membership in
`GameObj.targets` before every command and between array steps. Base does the same after
settling RT, against the live list, because the wait is when kills land.

**Stance dance (`change_stance`).** Skip if 216 active, dead, or in the ooze; perfect stance
numbers map to the named band; no-op if already there; a defensive request under cast RT is
dropped when already guarded; confirm with the five reply lines. This is now
`Lich::Gemstone::Stance.change` (#1578), and the engine's Stance action calls it.

**Cast (`cmd_spell`).** Release a different prepared spell; 597's 5 mana penalty; per-spell
cooldown gates (506, 9605, 9625, 335, 720, short buffs); 608 not while hidden; 703 / 1614
once per target; skip a dead target except 902 / 411; wand if OOM else wrack else rest; incant
path saves `after_stance`, goes offensive for stance spells, casts, returns to hunting stance,
restores `after_stance`; selfcast clears and re-sets the target. Ported at the Cast step.

## Target selection: bigshot's rules (step 2 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`should_flee?` 6866, `valid_target?` 6903, `sort_npcs` 6951,
`priority_matchers` / `priority_rank` / `priority` 6979-7008, `find_target` 7010,
`find_routine` 5980, `gameobj_npc_check` 5733, `check_boons` 6792, `invalid_target_with_boons`
6833, `do_hunt` 6146, `clean_value` for `targets` 2998). Now `EO::Engine::Targets`.

**The roster is the game's list.** Everything reads `GameObj.targets`, the game's own target
dropdown: hostile, alive, with much noise already removed. A creature not in it is not a target,
whatever GameObj.npcs says. It is rebuilt wholesale, so a fighting target can drop out for a
moment; priority compares ranks, not identity, for that reason.

**Exclusions**, in bigshot's order (`should_flee?` 6887-6896, `valid_target?` 6910-6913):
status dead or gone; the profile's `invalid_targets` by name or noun; names the game refused to
TARGET (learned, kept in CharSettings); appendage nouns (arm, appendage, claw, limb, pincer,
tentacle, palpus); the summoned and haze noun list (grik, verlok, imp, abyran, haze, mist, fog,
darkling, ...); the troll king and its severed parts; companions and familiars unless also
aggressive; "animated" anything except animated slush (and an animated decoy is also learned
as untargetable); a boon creature whose ASSESS abilities include one on `boons_ignore`. The
engine has these as `Targets.excluded_reason`, each with a reason symbol.

**Wanted.** The `targets` setting is `name(letter), name, ...`; a name is matched as an anchored,
case-insensitive regex against name and noun (`sort_npcs` 6973, `priority_matchers` 6982), so
regex fragments in the setting keep working. Empty means everything with routine `a`. One
discrepancy in bigshot: `valid_target?` (6942) matches unanchored, so `kobold` there accepts
`kobold shaman` while `sort_npcs` and `priority` would not. The engine anchors everywhere,
matching #2456's own comment on why priority was anchored.

**Order and priority.** Rank is position in the targets list, unlisted is infinity; the
game's order breaks ties. `find_target` keeps the current target while it is valid; with
`priority` on, a creature with a strictly better rank takes over (`best_rank >= target_rank`
keeps the target). `do_hunt` (6169) re-runs `find_target(nil)` when the current target loses
priority. `Targets.choose(roster, policy, current:, priority:)`.

**Routine.** The letter for the creature's entry, `a` when unlisted, `quick` for quickhunt;
the `disable_commands` override when fried in a group (`find_routine`). `Targets.routine_for`.

**Boons.** ASSESS once per creature id, cached until rest; adjectives map to ability names
(the table at 2596); `boons_ignore` excludes, `boons_flee` is a flee trigger. The engine has
the table and the parser; the ASSESS send is an Engage action.

**Learned targetability.** Before fighting a name for the first time, `target #id`; "You are
now targeting" marks the name targetable, "You can't target" / "origin" lines mark it
untargetable, both persisted. An Engage action, since it sends.

**Counts for flee.** `flee_count` is compared against the fightable count of the roster,
wanted or not (`should_flee?` 6900); `lone_targets_only` makes that 1 on entering a room.
`Targets.fightable_count`. The rest of `should_flee?` is the Flee step.

## Attack and cast: bigshot's rules (step 3 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`cmd` 3499-3503 for the bare attack path, `cmd_ranged` 5324,
`cmd_spell` 4867, `cast_spell` 4830) and Lich (`Spell#cast` spell.rb 583, `@@results_regex`
spell.rb 35, `Combat::Definitions::Attacks` defs/attacks.rb, `Combat::Observers` and the
Tracker's `emit_attacks` setting). Now `Actions::Attack` and `Actions::Cast`.

**Attack is not confirmed in bigshot.** `attack`, `kill` and the UAC verbs fall through `cmd`
to a bare `bs_put`, so the ladder's first non-refusal line is all bigshot ever sees; roundtime
paces the next command. `cmd_ranged` is the exception: `fire` waits 2 s for `round(time)?`,
`You cannot`, `Could not find`, `seconds` or `Get what?`, stows the wrong item on "You cannot
fire", and rests on "no effect" (unblessed ammo) or an unknown answer. The engine's Attack
does what `fire` does, for every verb: the first line must be an initiation line the combat
defs know (every second-person pattern in `Attacks::ALL_ATTACKS`, so a new def in Lich is
picked up here with no engine edit), or a refusal it can name (referent missing, weapon
missing, out of reach, hidden, muckled, hands full, no target). Anything else is a timeout the
watchdog counts.

**Observers and misses.** Observers emit per-creature facts (damage, wound, fatal crit, status,
stun, roundtime) and, with `emit_attacks` on, the whole parsed swing as one `:attack` event
whose `outcomes` list carries the miss, evade, block and hit lines. Misses are there, in the
blob, which is what the combat_stats recorder reads; there is no separate `:miss` fact.
`emit_attacks` is off by default and the Tracker has to be enabled, so the engine owns both
switches at start rather than assuming them. Attack therefore has two layers: the swing is
confirmed on the initiation line, which works with the Tracker off and answers "did the
command take"; the outcome, damage and kill come from the `:attack` event filtered to our own
swings (the blob flags inbound and foreign ones). The outcome layer is Engage's per-target
bookkeeping, built on top of a confirmed swing.

**Cast is Spell#cast, classified.** bigshot never sends a spell itself: `cast_spell` calls
`Spell#cast` / `force_cast` / `force_channel` / `force_evoke` by the extra word, or
`force_incant`, then reads the return: `Be at peace` / `Spells of War` / `Cast at what` are
`:blocked`, `[Spell Hindrance` retries up to three times, anything else is `:success`.
`Spell#cast` itself does the prepare, release of a different spell, the offensive stance and
the return to `after_stance` or guarded/defensive, and the stun retry. The engine's Cast
keeps exactly that shape and adds the reasons bigshot folds into "success": no target, cannot
prepare (the wound and concentration refusals), no mana, fizzled (the anti-magic room). It
does not go through Base's ladder, since `Spell#cast` has its own; that makes a cast the one
action `stop!` cannot interrupt mid-flight, which is also true of bigshot.

**What stays in Engage (`cmd_spell` 4867-4937).** Release a different prepared spell before
the cooldown gates; 597's five mana penalty; the per-spell cooldown gates; 608 not while hidden;
703 and 1614 once per target; skip a dead target except 902 and 411; wand if OOM, else wrack,
else rest; the hunting-stance restore after an incant, which is now `Lich::Gemstone::Stance`;
selfcast clearing and re-setting the target. These decide whether to cast; Cast decides how.

## Rest: bigshot's rules (step 4 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`ready_to_rest?` 7233, `should_rest?` 7269, `ready_to_hunt?` 7179,
`should_hunt?` 7208, `fried?` 7036, `oom?` 7043, `overkill?` 7068, `lte_boost?` 7078,
`use_lte_boost` 7083, `add_overkill` 7302, `check_mind` 7100, the dread and poison predicates
7133-7162, `rest` 6226, `pre_hunt` 6037, `fog_return` 6463, `goto` 6681, `prepare_for_movement`
7502, `prep_and_rest_commands` 5890, `run_script` 5835). Now `EO::Engine::Rest` (Policy,
Counters, Predicates), `Behaviors::Rest`, `Actions::Command`, `Actions::LteBoost`.

**When to rest (`ready_to_rest?`), first reason wins, in this order:** a forced reason
(`$bigshot_should_rest`: an unknown command result, an unreachable room, bounty complete);
`wounded_eval`; fried, which is mind at or past `fried` *and* every `lte_boost` redeemed *and*
`overkill` extra kills since; encumbrance at or past `encumbered`; Creeping Dread level at or
past `creeping_dread`, read from the "(N)" in the debuff name; Crushing Dread the same; Wall of
Thorns Poison when `wot_poison`; the Confused debuff when `confusion`; mana below `oom` after
one wrack attempt when `use_wracking`, with a negative `oom` disabling the check. `fried` above
100 disables fried. `Predicates.rest_reason` reproduces the list; the wrack attempt is Maintain's
and the group merge (`should_rest?` 7272-7290: all-fried-but-not-everyone keeps hunting, a
wounded rest waits for stunned members) is M3.

**When to hunt again (`ready_to_hunt?`), in this order:** wounded; encumbered; either dread
active at its threshold; Confused; thorns poison; a resting script still running; mind above
`rest_till_exp`; mana below `rest_till_mana`; spirit below `rest_till_spirit` (an absolute);
stamina below `rest_till_percentstamina`. Checked every `rest_interval` seconds.
`Predicates.not_hunting_reason`.

**Fried bookkeeping.** `check_mind` reads `Experience.percent_fxp` before every check. When
fried with boosts left, `boost longterm`: "deducted 500 experience points" counts a boost and
zeroes the overkill count; "do not have any" marks every boost spent so overkill takes over.
Each kill while fried and boosted counts one overkill. Both counters reset when a rest begins.
`Counters`, `Actions::LteBoost`; the per-kill count is Engage's.

**The cycle (`rest` then `hunt`):** stop the hunting scripts and drop to `wander_stance`
(`prepare_for_movement`); escape rooms; fog by `fog_return` unless it is 0, or `fog_optional`
and the reason is not wounded or encumbered; go2 each `return_waypoint`; go2 `resting_room`;
`resting_commands` then `resting_scripts` ("script name args" starts one, killing a running or
paused copy first); wait until ready; `hunting_prep_commands`; go2 each `rallypoint`;
`hunting_scripts`; go2 `hunting_room`, up to five attempts, a miss being a forced rest reason
("Could not reach"); autosneak on when `sneaky_sneaky`. `Behaviors::Rest` runs that as one
step per tick, so pause and stop land between steps; the travel steps call libeo's `EO.go2`
and `EO::Fog.return` and block for the trip the way bigshot's do, until the Travel step
supervises them. Left for later steps: escape rooms and sneaky (Survival, Maintain), signs,
bless and 902/411 (Maintain), the bounty exit (Objective), every follower wait (M3).

## Flee: bigshot's rules (step 5 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`should_flee?` 6866, `should_flee_from_boons?` 6847, `hunt_monitor`
2322-2383, `bs_wander` 7562, `bs_move` 7539, `escape_rooms` 7728, `creature_escape` 7791,
`find_escape_weapon` 7745, `temporal_escape` 7859, `attack_break` 6512, the weapon regexes at
2749). Now `EO::Engine::Flee` (Policy, Predicates), `Behaviors::Flee`, `Wander::Walker`,
`Actions::Move`, `Actions::Escape`, and `Watch`, the engine's one DownstreamHook.

**A flee is a step, not the FLEE verb.** `should_flee?` true breaks every command loop
(`attack_break`, `cmd_*`, `wait_for_swing`) and `do_hunt` falls into `bs_wander`, which skips
`wander_wait` and steps to the next room by `bs_move`: the room's exits minus
`hunting_boundaries` minus gates whose proc answers nil, rooms not walked lately first, else
the least recently walked. "You bolt" clears the latches. The engine's Flee behavior takes one
such step per tick through `Wander::Walker`, which Wander shares, and `Actions::Move`, confirmed
by the room counter (a String way is a move with a 5 s timeout, a proc way is called).

**Triggers (`should_flee?`), in bigshot's order:** quick mode never flees; the profile's
`flee_message`, matched against every line by `hunt_monitor` and latched until a bolt; a hazard
on the object list by toggle (clouds and the shimmering circle, vines, webs, black voids);
`always_flee_from` by creature noun or name, or player name; bandit hunting stops here; a boon
creature with an ability on `boons_flee`; a follower alone (M3); more fightable creatures than
`flee_count`, where `lone_targets_only` makes that 1 on entering a room. The ambusher latch
from `hunt_monitor` ("leaps from hiding to attack" by a non-member, or "flies out of the
shadows") is separate in bigshot, blocking `no_players_hunt`; the engine folds it in as a
reason right after the message. `Flee::Predicates.reason` returns the reason symbol.

**Escape rooms** (`escape_rooms`, run before every command and after every command set):
The Belly of the Beast is `attack wall` with a dagger-class weapon; Ooze, Innards is `kill
organ` with a blunt; both wield from the right hand, else search worn items and containers,
opening closed ones; no weapon at all stows and waits to be spat out; the loop ends when the
room changes or the game answers "What were you referring to". Temporal Rift is random moves
until out. `Actions::Escape`, wielding through `Lich::Stash.wield` (lich-5 #1579) and bounded
where bigshot waits forever. Which behavior runs it is Survival's call; the action stands alone.

**The Watch.** `hunt_monitor` is one DownstreamHook of about thirty rules. The engine's
`Watch` is that as a rule table: a regex, an event name, a data block; the hook passes every
line through untouched. It must be installed by the running script, not the library, because
Lich removes a dead script's hooks and a library script exits on load. Step 5 registers the
ambusher lines, the bolt, and the profile's flee message; later steps add theirs (weapon
reaction, smite and 703 lists, arrows stuck, unarmed tiers, Swift Justice, rooted).

## Maneuvers: bigshot's rules (step 6 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`cmd` dispatch 3410-3427, `cmd_assault` 3759, `cmd_weapons` 3859,
`cmd_shields` 3932, `cmd_cmans` 4092, `cmd_feats` 4213, `cmd_bearhug` 4330, `cmd_rogue_cmans`
4382, `cmd_warrior_shouts` 4458, `cmd_burst` 5405, `cmd_surge` 5425, `cmd_mstrike` 5162,
`mstrike_spell_check` 5134, the mstrike settings 2931-2938) and Lich's PSM readers
(`PSMS.command` / `PSMS.results_regex` and the per-category `.command` / `.results_regex`,
lich-5 #1583). Now `Actions::Maneuver` and `Actions::Mstrike`.

**The technique is Lich's data, the routine is bigshot's.** Every `cmd_*` routine is the same
shape: a word-to-name table, `X.available?` then `X.affordable?`, `waitrt?` / `waitcastrt?`,
then `dothistimeout("verb word #id", 1, complete_regex | ...wait)` in a 2 s loop that waits
out roundtime and re-checks affordability, breaks on any complete line, and turns `false`
(no answer) into a forced rest reason. The reader now gives the command and the result regex,
so the engine's Maneuver is one class for all five categories: the gate order (known, buff
already up when asked, Overexerted, affordable, cooldown), the reader's command with the
creature by id or a word such as ALL, `send_and_match` on the reader's regex plus bigshot's
extra lines, and a named reason for every refusal bigshot lists (referent missing, already
dead, out of reach, awkward, too injured, hidden, no target, hands full, confused, no momentum,
cooldown, the mstrike lockout, no shield, no weapon, not a member, rooted). No answer is
`:no_confirmation`, which the watchdog counts where bigshot rested.

**Per-kind details kept:** assaults read for 10 s and 12 s in all, bearhug 16 and 17, the rest
1 and 2; a Barrage refused for "attack as the attack type" swaps hands once and resends;
`shield bash` is the CMan when known, else the Shield technique; BURST and SURGE skip when
their buff is up and may fire during an ignorable cooldown (`ignore_cooldown`, the 60-stamina
case); warcries send ALL as a word and the rest by id. FORCERT is the reader's (`forcert_count`),
never on an assault. `Maneuver::WORDS` is bigshot's routine vocabulary for Engage's compiler.
Dropped: the stamina table in `cmd_warrior_shouts` (the reader's cost data), the per-cman
cooldown checks for Spell Cleave and Spell Thieve (the reader's `available?`).

**Mstrike (`cmd_mstrike`):** never while Overexerted; never with a nest in the room; 30 MOC
ranks for a focused strike, 5 for an unfocused one; unfocused when the fightable count reaches
`mstrike_mob` or there is no target; during the Multi-Strike cooldown only when
`mstrike_cooldown` and stamina is at `mstrike_stamina_cooldown` (default max stamina);
`quickstrike 1` in front when `mstrike_quickstrike` and stamina is at
`mstrike_stamina_quickstrike` (default max). The command carries the unarmed word
(`mstrike jab`). bigshot sends it bare; the engine confirms on the start lines of Lich's
`:mstrike` sequence. `mstrike_spell_check` (Rejuvenation 1607, Adrenal Surge 1107 for Paladins
and Empaths) is Maintain's; the `$mstrike_taken` hand-off to the plain unarmed swing is
Engage's.

## Wander: bigshot's rules (step 7 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`bs_wander` 7562, `bs_move` 7539, `do_hunt` 6146, `no_players_hunt`
6029, `bigclaim?` 5921, `BSAreaRooms` 620-717, `prepare_for_movement` 7502, `cmd_hide` 5121,
`reset_variables` 7105, the settings 2861-2897). Now `EO::Engine::Wander` (Policy, Area,
Predicates), `Behaviors::Wander`, `Actions::Hide`; `Wander::Walker` and `Actions::Move` are
step 5's.

**The loop between fights.** `do_hunt` calls `bs_wander` whenever `find_target` has nothing,
and `bs_wander` is: drop to `wander_stance` (`prepare_for_movement`, which also blesses and
casts signs); if the room is ours (`bigclaim?`) or we did not just enter it, look for a valid
target with the just-entered flag on, sleep `wander_wait`, look again with it off, and return
the first found to the attack loop; otherwise cast signs, wait for followers and looting, hide
when `sneaky_sneaky` (`cmd_hide(1)`), wait roundtime, run `escape_rooms`, Ranger track, then
`goto(hunting_room)` when outside the area or `bs_move` one step. The engine's Wander is the
bottom of the priority list, so Engage takes any creature the moment it shows and Wander's
question is only "is there nothing to fight here": `Predicates.fight_here?` is the claim plus a
`Targets.candidates` hit. Its tick is one thing: the wait (only in a room that is ours; a
claimed room is left at once), the stance drop once per room, the hide when sneaking, the trip
home when outside the area, else one Walker step through Move. Each new room emits
`:entered_room`, which is where bigshot's `reset_variables(moved)` lists (smite, 703, 1614,
the ambusher) get cleared by whoever owns them.

**The claim (`bigclaim?`).** Ours when Lich's `Claim.mine?` and every disk in the room is the
group's, unless `ignore_disks`. A follower and quick mode always say ours; both are the
script's. `World#claim_mine?` and `World#foreign_disks`.

**The area (`BSAreaRooms`).** Breadth-first from the hunting room through exits whose timeto
is numeric (a StringProc is called and must answer a number), minus `hunting_boundaries`. Two
hundred rooms means a boundary is missing: bigshot prints the first three location changes and
exits; `Wander::Area#too_big?` and `location_changes` hand that to the script. The area is
built once by the script, and a Wander with no area never goes home.

**Left where it belongs:** bless and signs before moving (Maintain); `escape_rooms` (Survival,
priority 0, from step 5's Escape); followers, looting waits and the final loot (M3, Loot);
bandit and Ranger tracking (Objective); `goto` is libeo's blocking `EO.go2` until the Travel
step; a failed trip home returns `:could_not_reach` for the script to turn into a forced rest
the way bigshot's `goto` does.

## Loot: bigshot's rules (step 8 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`need_to_loot?` 6578, `loot` 6620, `looting_watch` 6657,
`run_script` 5835, `add_overkill` 7302, `use_lte_boost` 7083, `time_between` 2820, the calls at
`attack_break` 6575, `should_rest?` 7294 and `bs_wander` 7618, the settings 2876-2956). Now
`EO::Engine::Loot` (Policy, Predicates), `Behaviors::Loot`, `Actions::Loot`.

**When (`need_to_loot?`), in order:** the claim without the disk check; the leader (M3); not in
the Duskruin arena or an escape room; not fleeing and no ambusher (Flee outranks Loot, so
implicit); followers done looting (M3); a corpse here that is not an escort, else nothing to
fight and loot on the floor; with `delay_loot` and something still to fight, only every fifteen
seconds. bigshot asks after every command set; the engine asks every tick at priority 30, so a
corpse is looted before the next swing unless delayed. `Predicates.reason` gives `:corpses` or
`:floor`; looted corpses are remembered per room so LOOT is not resent to the same body.

**How (`loot`):** `loot_stance` drops to defensive while creatures are still up; per corpse,
`use_lte_boost` then `add_overkill` (one extra kill when fried with the boosts spent), then the
loot script or `loot #id` and `loot room`. The loot script loots the whole room, so it runs once
for every corpse present and the engine waits a tick at a time (`looting_watch`): a script that
pauses with a box in hand could not store it, is killed, and that is the forced rest reason
"Box in hand, couldn't store" (`:loot_stuck`). The floor is looted only on a final loot.

**The final loot** is asked for by two callers: `should_rest?` before leaving for dread, bounty,
fried, mana or encumbrance (never wounds) in a room that is ours, and `bs_wander` before leaving
any room when `final_loot`. `Behaviors::Loot#final!` is that request; `Policy#final` is the
profile toggle. The rest caller cannot be an event: Rest outranks Loot, so a request left for
Loot never got a tick before Rest left the room (review, 2026-09-10). Rest now takes `loot:`
and has a `:final_loot` phase before `:leave` that drives Loot's own ticks until Loot has
nothing left here (capped at `FINAL_LOOT_TICKS`), then leaves.

## Maintain: bigshot's rules (step 9 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`cast_signs` 7357, `cast902` 7330, `cast411` 7340, `check_902_411`
7350, `cmd_bless` 4629 and its `hunt_monitor` lines 2359-2367, `display_items_for_blessing`
6741, `wrack` 5743, `cmd_rapid` 5065, `bard_renewal` 7315, `mstrike_spell_check` 5134, the
`cmd_spell` OOM branch 4894-4907, the settings 2875-2942). Now `EO::Engine::Maintain` (Policy,
State, Signs, Stamina), `Behaviors::Maintain`, `Actions::Wrack`, `Actions::Bless`,
`Actions::WeaponBlessCheck`.

**Signs (`cast_signs`)** run before every command, before every move and once after every
step, so they are effectively kept up all the time; the engine's Maintain at priority 40 asks
every tick and casts one due sign per tick, in list order. Each entry is read the way bigshot
reads it: `650 a b` is Assume Aspect through the routine's own `Actions::Assume` when 650 is
known and affordable, neither aspect is up and both are not cooling down (cmd_assume's own
gates), `515` / `rapid` / `rapid (ignore)` is Rapid Fire with its buff, recovery-cooldown
and ignore-word gates, `122420` is Seanette's Shout when Empowered has under ten seconds and
stamina is 25, `9605` and `9625` are Surge and Burst at 30 stamina off cooldown, `909` is a
force_channel when inactive, `902` and `411` are the weapon blesses gated by a quiet LOOK at the
right hand ("gleams faintly with inner light", "surrounded by a scintillating"), everything else
is a spell number. A spell is due when known, not 9918, not a Voln symbol under 9012, not
priced out by 597's five-mana penalty, not on its cooldown (320 Ethereal Censer, 605 Barkskin,
1035 by the Song of Tonis buff, the short buffs 140/211/215/219/240/919/1619/1650 by name), not
active, within Voln favor for 9805/9806/9816 when `check_favor`, affordable (else wrack when
`use_wracking` and the real cost exceeds mana), a Bard's renewal cost covered, and 1.5 s past
its last cast. `Signs.due` returns why. The hindrance retry is Cast's.

**Bless (`cmd_bless`).** The Watch reports an item that "strikes true" but is shrugged off when
it is our ammo, in our inventory or in hand, and any item whose blessing "returns to normal";
those ids are `State#bless_wanted`. With the `bless` toggle on, Maintain blesses the newest
first, before any sign: 1604 at it, else 304 at it, else SYMBOL BLESS, else "No blessing on
weapon" is the forced rest reason (`:maintain_stuck`) and the list is cleared. With the toggle
off the list is only for the rest-time reminder, which is the script's.

**Wrack (`wrack`):** Sign of Wracking when known, 9012 not up, spirit at `wracking_spirit` and
at 6 plus one per active 9912/9913/9914/9916; else Sigil of Power once per fifty stamina; else
Symbol of Mana off cooldown. The engine reads Lich's Society readers (`CouncilOfLight`,
`GuardiansOfSunfist`, `OrderOfVoln`: `known?`, `affordable?`, `available?`, and the entry's
usage) rather than Spell numbers; CoL's `affordable?` already counts the spirit the active
dissipating signs still owe, which is bigshot's 6-plus-count. Their `use` sends bare with its
own `waitrt?` and reads nothing, the PSM `use` problem again, so the engine sends the same
command itself and confirms on mana rising. Called for a sign here and by Engage's `cmd_spell` OOM branch,
which also wands first when `wand_if_oom` (Engage's).

**Stamina before an mstrike (`mstrike_spell_check`):** Paladins and Empaths only; Rejuvenation
1607 when inactive and its gain (15 plus 3 per Blessings rank step) reaches the mstrike floor;
Adrenal Surge 1107 once per 301 s when 9010 is not up and popped muscles are, or the estimated
gain (max stamina at 65 ranks, +50 at 35, +25 below) reaches the floor. `Stamina.top_up_spell`
names the spell; Engage casts it before its Mstrike.

## Survival: bigshot's rules (step 10 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (the main loop's stand 8219, `stand` 5901, `escape_rooms` 7728 and its
calls at `cmd` 3305 and `bs_wander` 7638, `check_for_deaders_prone` 3260, `group_member_stunned?`
5632, `dead_man_switch` 5664, the `hunt_monitor` lines 2406-2416, the settings 2872-2959). Now
`EO::Engine::Survival` (Policy, Predicates), `Behaviors::Survival`, `Actions::Stand`,
`Actions::Pull`, `Actions::Depart`.

**bigshot has no survival layer;** it has a stand at the top of the follower loop and before
every command, `escape_rooms` and `check_for_deaders_prone` before every command, and a
`dead_man_switch` thread. The engine's Survival is the behavior at priority 0, so nothing else
runs through any of these. `Predicates.reason`, in order: dead; an escape room by title (step 5's
Escape); a dead player with the `deader` toggle; not standing, unless resting or muckled; a
player to pull.

**Stand (`stand`):** drop to `stand_stance`, STAND until standing, restore the stance we had;
never in the ooze. The kneeling-crossbow exception (5904, skip the stand when the next command
is fire, kneel, hide or 608) is Engage's, since it knows the next command. Bounded to three
sends.

**Pull (`check_for_deaders_prone`):** with `pull` on and an aggressive creature up, PULL any
player sitting, lying or prone and alive; group members always. **Deader:** with `deader` on, a
dead player here pauses bigshot until `;u bigshot`; the engine reports `:deader` once per room
and holds there, so the pause and the resume are the script's. `group_member_stunned?` (us, or a
member by status) is here for Rest's wounded wait (M3).

**Death (`dead_man_switch`):** GSF quits; the depart switch departs twice with confirm, starts
ewaggle, waits for full spirit, and restarts solo; otherwise the script is killed. `Policy#on_death`
is `:stop`, `:depart` or `:quit`; `:died` is emitted once; ewaggle and the restart are the
script's.

**Watch lines:** held in place ("don't seem to be able to move", the snake's coils) and freed
set `Survival#rooted?`, which Engage reads to turn kicks into punches (3318); the item-limit
lines emit `:too_many_items`, bigshot's "Too many items" forced rest, for the script.

## Engage: bigshot's rules (step 11 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`do_hunt` 6146, `attack` 6533, `attack_break` 6512, `find_routine`
5980, `command_check` 3539, `check_state_condition` 3589, the modifier tables 2634-2678,
`cmd` 3296-3507, `once_commands_register` 3509, `repeatdelay_blocked?` 3520, `cmd_spell` 4867,
`cast_spell` 4830, `valid_target?` 6903 with its TARGET probe 6928, `find_target` 7010,
`priority` 6991, `wait_for_swing` 5794, `cmd_ambush` 5479, `cmd_run_script` 5458, `cmd_sleep`
5468, `cmd_hide` 5121, `hunt_monitor` 2387-2405). Now `EO::Engine::Engage` (Policy, State,
Routine, Conditions, SpellGates), `Behaviors::Engage`, `Actions::Target`, `Actions::WaitForSwing`,
`Actions::Ambush`; `Actions::Attack` takes a `command:` override.

**The loop.** `do_hunt` finds a target, `attack` sets TARGET #id when the game is not on it and
runs the routine's lines through `cmd`, checking `attack_break` before each: no claim, target no
longer valid, a rest, an ambusher, a better target with `priority`. The engine's Engage at
priority 50 runs one line per tick, so every other behavior lands between lines the way
`attack_break` allows; the claim and the wanted-creature test are `wants_control?`; the target
is `Targets.choose` each tick (the current one while valid, a strictly better rank with
`priority`). A new target restarts its routine from the top; the routine is the creature's
letter from the targets list (`find_routine`), `quick_commands` in quick mode; `disable_commands`
for a fried group member is M3.

**The TARGET probe.** `valid_target?` sends TARGET #id to a creature it has not seen and learns
"untargetable" names from "You can't target" and the origin lines, keeping them in CharSettings
across sessions. The engine's `Actions::Target` is that send; a refusal adds the name to the
targets policy's untargetable set, emits `:untargetable_learned` for the script to persist, and
drops the creature.

**Modifiers (`command_check`).** A trailing parenthesis holds words, each a reason to skip the
line now: the amount words (`e`, `essence`, `h`, `k`, `m`, `mob`, `s`, `tier`, `v`, `valid`, with
`!` negation), `buffN` against the technique's buff, `repeatdelayN` against the room registry,
`ES"…"`/`EB"…"`/`EC"…"`/`ED"…"` against the four Effects dialogs, the buff words (barrage, celerity,
flurry, fury, garrote, holler, momentum, pummel, rapid, rebuke, scourge, shout, tailwind, thrash,
vigor, yowlp, animate, burst, surge, bearhug, voidweaver), our state (disease, poison, hidden,
outside), the creature's (ancient, flying, frozen, noncorporeal, undead, prone, rooted), the
unarmed tier, `once` and `room` against the registry, `splashy`, `pcs`, `justice`, `reflex`.
`censer` (cast 320 first) is not yet. `Conditions.blocked_by` names the blocking word; the
registry is per room, cleared on `:entered_room`, and records every line that ran.

**Dispatch (`cmd`).** `target` in a line becomes `#id`; the hunting stance is set before every
line except numbers, wait, sleep, wand, berserk, script, hide and nudgeweapon. Then by verb: a
spell (with `cmd_spell`'s gates: 597 penalty, 506 active, surge/burst/335/720 and short-buff
cooldowns, 608 while hidden, 703 and 1614 once per target, a dead target unless 902/411;
unaffordable means wand when `wand_if_oom` (Engage reports `:wand_if_oom`, the wand routine is
later), else wrack when `use_wracking`, else the "out of mana" rest reason unless `oom` is
negative; a bare 506/902/411 casts at nobody; an incant restores the hunting stance after);
`mstrike` with Maintain's stamina top-up first; `hide N`; `script name args` (blocking, as
bigshot); `sleep N [nostance]`; `stance X`; `wait N` (WaitForSwing: the wander stance, until the
target's line ends on us, it goes prone, the room empties or N passes); `ambush [part]` cycling
the profile's ambush parts on a refused part; the maneuver words through Maneuver (a category
prefix such as `cman bullrush` is stripped; warcries with `all`, shout/yowlp/holler untargeted);
the attack verbs through Attack with the line as sent; everything else as a bare command. Not
yet, reported once as `:routine_unsupported`: resonance, jewel, throw, weed, wand, wandolier,
unarmed (the tiers and follow-ups), smite, caststop, unravel, stomp, leech, rapid, depress,
phase, curse, efury, dhurl, briar, assume, wield, store, tether, sacrifice, nudgeweapons,
berserk, force, eachtarget, dislodge, and the celerity/slayer/tonis prefixes.

**Watch lines:** Swift Justice charges and the unarmed positioning tier into `State`; a
creature's line that ends on us is `:incoming_swing` for WaitForSwing (player names are M3).
Weapon reaction (`perform_reaction`) and the soothe routine (1201) are later.

## Travel: bigshot's rules (step 12 of the rebuild, 2026-09-10)

Read from bigshot 5.16 (`goto` 6681, `go2` 6673, `run_script` 5835, the follower waits
around every trip in `pre_hunt` 6037 and `bs_wander` 7644) and libeo's `EO.go2` / `EO.at?`. Now
`EO::Engine::Travel` (Trip, step, cancel); Rest and Wander drive their trips through it.

**A trip is the go2 script, supervised.** `goto` unhides, runs go2 up to five times, and blocks
until it ends, calling `escape_rooms` between attempts; a fifth miss is the forced rest reason
"Could not reach". Rest and Wander used libeo's blocking `EO.go2` for that, which meant pause and
stop could not land during a trip and a death or an escape room mid-trip waited for go2 to give
up. `Travel::Trip` starts the same go2 script and watches it a tick at a time: arrival by room
id, server uid or map tag (`Trip#at?` on World) ends the script; a go2 that ended short is one attempt; five
attempts is `:could_not_reach`; `cancel!` kills go2, and the engine's `stop!` cancels every
behavior's trip. Survival outranks the trip's holder, so an escape room or a death mid-trip is
handled between ticks the way `goto`'s `escape_rooms` call did between attempts.

**The seam.** Rest and Wander take a `travel` callable of (room) that answers a Trip, or, for
the old blocking style and for specs, true or false; `Travel.step` drives either and keeps the
trip on the behavior until it is done. The five attempts live in the Trip now; Rest's own
five-count over a whole trip is kept so a profile's `resting_room` still gets bigshot's
"Could not reach" after five full trips. Follower waits around trips are M3.

**Ownership and preemption (review, 2026-09-10).** A trip belongs to the behavior holding
control. The engine remembers who ticked last and, when control changes hands (a higher
behavior, idle, or pause), calls the previous holder's `preempted!`; Rest and Wander answer
with `Travel.suspend`, which kills go2 and keeps the trip, so Flee or Cleanse never issue
commands while go2 is still walking. The next step the holder takes restarts go2 from wherever
we are, not counted as an attempt. `Travel.claim`/`release` keep one go2 at a time: a trip
starting go2 suspends any other trip still underway.

**Off libeo (2026-09-10).** The fog for methods 1-5 is `Lich::Gemstone::Fog` (lich-5 #1584),
with libeo's `EO::Fog` loaded only on a Lich without it; method 6, the profile's `custom_fog`
commands, is Rest's own `:custom_fog` phase, one line per tick, confirmed on the server uid
changing. The hurl recovery no longer travels: the throw and the recovery are one action in
one room, and a weapon elsewhere is a disarm for Cleanse. Nothing else in the engine calls
libeo.

## The M0 spike: eohunter.lic on a bigshot profile (2026-09-10)

`EO::Engine::Profile` reads a bigshot profile YAML with `load_settings` / `clean_value`'s
rules (2833-3014: to_i, to_f, split, split_xx with (xN)/(xx)/"and", the name(letter) targets
list, "u1234" uids to ids) and builds every behavior's Policy from it, so a profile that runs
under bigshot runs here unchanged. `wounded_eval` is evaluated in the script's binding, as
bigshot's `wounded?` does.

`scripts/eohunter.lic <profile> [dry]`: loads libeo and the engine, reads the profile, builds
World, the Walker and the Area (refusing to hunt when the area is unbounded, where bigshot
exits with its table), the seven behaviors on bigshot's priority ladder, wires the events to
front-end messages and to the forced-rest reasons (`out_of_mana`, `loot_stuck`,
`maintain_stuck`, `too_many_items`, `rest_stuck`), persists learned untargetable names to
CharSettings, asks Loot for the final loot when a rest starts for bigshot's reasons, stops on
death (or departs/quits by the profile) and on a dead player (bigshot pauses; the resume is
manual either way), installs the Watch, and runs the engine loop until killed. `dry` reports
the policies and exits.

First profile: `ojandhaart` (ranger, sneaky, eloot delayed, routine kweed / script volley /
coupdegrace / 608 / hide / fire). kweed is `cmd_weed` (4797) in Engage now. Still reported as
unsupported from that routine: nothing; `script volley` blocks for the script the way bigshot
does.

## Cleanse: ecleanse folded in (step 13 of the rebuild, 2026-09-10)

Read from ecleanse 2.3.6 (`main_loop` 1834, `set_hooks` 1618, `Data` 213, `load_defaults` 637,
`load_profile` 670, `Util.able_to_cast` 1666, `check_determination` 1712, and the Actions:
`remove_poison` 1361, `remove_disease` 1298, `remove_stun` 1390, `remove_web_bound` 1444,
`remove_grounded` 1314, `remove_magical` 1337, `dispel_cloud` 819, `avoid_globe` 716,
`avoid_webs` 686, `avoid_runestone` 748, `determination` 810, `settle_room` 1495, `recover`
1088, `recovered?` 1057, `record_disarm` 1078, `recover_weapon_webbing` 1240,
`telekinetic_recover` 1548, `sanctum_recover` 1470, `hive_search` 913, `hive_traps_apparatus`
947, `hive_traps_ground` 980, `itchy_curse` 993, `use_vat` 1587, `mana_pulse` 1027,
`stunman_perform` 1516). Now `EO::Engine::Cleanse` (Policy, State, Spells, Casting,
Predicates), `Behaviors::Cleanse` at priority 5, and one `Actions::Cleanse*` per ecleanse
Action. ecleanse is not absorbed as a standalone mode: Cleanse runs only inside eohunter.

**ecleanse's loop is a tick and its pause is the priority.** `main_loop` reads the conditions
every 0.2 s (poison or thorns, disease, stunned, webbed or bound, rooted or pressed, a
dispellable debuff, a cloud, a globe, a runestone, a web on the floor, a wound past the
determination threshold) and queues one event per condition; each Action pauses the other
scripts (`scripts_pause`) while it works. `Predicates.reason` is that list in that order, each
gated the way its Action gates itself (the setting on, the spell known, castable by the
injury rules, a means available) so the behavior only claims a tick it can use; queued line
events come first. Taking the tick at priority 5 is the pause, with nothing to unpause.

**The hook is the Watch.** The thirteen `set_hooks` rules become Watch rules: the four disarm
lines and the telekinetic and webbing ones carry the weapon noun and record the hands and
room at that moment (`State#record_disarm`, the 2.3.3/2.3.4 known-ids fix kept), the sanctum
transform carries the creature, the infected wound, the two hive trap families with the room,
the itchy curse, the entangling bind. `recover_disarmed` off means a disarm records nothing.

**The Actions** keep ecleanse's commands and gates and are bounded where it loops: the cures
cast up to six times; the stun means in ecleanse's order (barkskin, berserk, 1040, beseech,
then the Stun Maneuvers stances, flee and hide through `CMan.use` as 2.2.8 does); the
hazards TARGET first and a refusal marks the id bad for the session (the CappedCollection);
the recovery goes back to the room, casts 213/1011 by policy, tries the 218 servant, settles the
room, drops to defensive, waits ten seconds for a bonded return, else stows, kneels and
RECOVER ITEM up to ten times trusting the game's own "You spy" line first and the hand check
second, stands and refills; "not in any condition to be searching" is `:cleanse_stuck`, a forced
rest, where ecleanse exits. Hive traps keep their three attempts and twenty-second ceiling.
The three jobs that travel (the disarm recovery back to its room, the itchy curse to a safe
room and back, the vat to the Sanctum and back) are `Behaviors::Cleanse::Job`s of stages go,
act, return: one Travel trip tick or one action per engine tick, so the trip is supervised and
suspended when Survival takes control (review, 2026-09-10); a trip out that fails ends the job
with `:could_not_reach`, a failed way home is `:cleanse_stuck`. The actions themselves assume
they are in place. Settings come from `ecleanse.yaml` with the CharSettings defaults; the setup
window stays ecleanse's.

## The rest of the routine words (2026-09-10)

Read from the LOCAL bigshot 5.16.0 (`C:\Gemstone\dev\lich-5\scripts\bigshot.lic`, the
Creature-migrated one; the repo copy under `_WORKSPACES/scripts-libeo` is older and its line
numbers differ): `cmd_sacrifice` 6626, `cmd_tether` 6645, `cmd_efury` 6095, `cmd_phase` 4913,
`cmd_curse` 4689, `cmd_dhurl` 6295, `cmd_recover` 6343, `cmd_caststop` 4869, `cmd_depress`
4885, `cmd_unravel` 4930, `cmd_resonance_bolt` 5932, `cmd_stomp` 6041, `cmd_leech` 6060,
`cmd_rapid` 6076, `cmd_jewel` 5164, `cmd_briar` 5665, `cmd_assume` 5603, `cmd_throw` 5695,
`cmd_wield` 4564, `cmd_store` 4585, `cmd_nudge_weapons` 6592, `cmd_berserk` 6510,
`cmd_volnsmite` 5433, `cmd_unarmed` 5470, `cmd_wand` 5950, `cmd_wandolier` 5995, `cmd_ranged`
6375, `check_target_vitals` 6234, `cmd_dislodge` 6430, `cmd_force` 5713, `cmd_eachtarget` 4220,
the celerity/slayer/tonis prefixes 3359-3387, the soothe 3348, `perform_reaction` 8062, the
kick-to-punch 3318, and the `hunt_monitor` lines 2769-2837. Now `scripts/eohunter/routines.rb`:
`Engage::Routines.run` dispatches these words, one `Actions::*` per routine, and the Watch rules
that feed them (weapon reaction, arcane reflex, the smite and 703 and 1614 lists, arrows stuck
and aiming, the bonded return, the unarmed follow-up, the force endroll).

Every routine keeps bigshot's commands and gates and is bounded where bigshot loops: tether's
transfer chase stops after three, efury and tether hold twelve seconds, unravel six casts, the
hurl recovery eight reads, the unarmed read five seconds, force thirty. The wand routines'
"too injured" and "no fresh wands" and the unblessed-ammo "no effect" are events for the script
to turn into forced rests. Engage runs the soothe (1201 under a rage or song) and a pending
weapon reaction before every line, as `cmd` and `attack` do. Nothing in the routine table is
reported unsupported any more; a word outside it is sent bare, as bigshot's `cmd` sends it.

## Bandits and tracking (2026-09-10)

Read from bigshot 5.16 (`bandit_track` 9459, `ranger_track` 9488, `uncover` 9520, the last
look in `bs_wander` 9375 and the track call at 9427, `sort_npcs` 8622-8631, `priority` 8675,
`should_flee?` 8540, `hunt_monitor` 2760, `set_bounty_eval` 3824, the option parsing 3331 and
3357). Now `EO::Engine::Tracking` (Policy, `policy_from`, `bandit_targets`), `Actions::BanditLook`,
`Actions::Track`, `Actions::Uncover`, and Wander takes a `tracking:` policy.

**Bandits are not in the feed.** They show in the room text and nowhere else, so nothing
registers them and no `<crtrStatus>` ever arrives; `bandit_track` scrapes a quiet LOOK for the
first bandit noun (`bandit|brigand|robber|thug|thief|rogue|outlaw|mugger|marauder|highwayman`),
manufactures it with `GameObj.new_npc` and puts its id at the head of the game's target ids.
`Actions::BanditLook` is that, on two World seams (`look_lines`, `register_npc`,
`add_current_target`). Wander takes the look once per room after the wander wait, before
stepping out; a find is Engage's next tick, since the bandit is now in `room.targets`.

**Bandit mode relaxes the rules.** The target list becomes the bandit nouns on the quick
routine (`Tracking.bandit_targets`, an anchored alternation for `Targets::Policy`); priority
never switches (`engage_policy.priority = false`); `should_flee?` answers nothing past
`always_flee_from` and the ambusher hook is off (`Flee::Policy#bandits`), because a bandit fight
is an ambush by design. Hazards and always_flee_from still flee. It is on for the word
`bandits` or when the bounty says "suppress bandit activity", as bigshot's bounty mode does;
bounty completion stays ebounty's.

**Ranger tracking.** `;eohunter <profile> track <creature>` names the quarry. Before each
wander step, a Ranger off the Tracking cooldown sends TRACK <creature> (`Actions::Track`): a
trail means the game moved us and we stay; "You don't have to go far" means it is hidden here,
so we stay when the room is ours and move on when it is not; too old, no trace, town or
cooldown move on. When we stay with nothing hostile showing, `Actions::Uncover` sends 609 open
for a Ranger who can afford it, else SEARCH, as `uncover` does. Once per room.

## Troubadour's Rally (2026-09-10)

Read from bigshot 5.16 (`group_status_ailments` 6713, called before every command in the
attack loop at 7799; `cmd_1040` 6271; `group_member_stunned?` 6727 in `should_rest?` 9035; the
`troubadours_rally` toggle 3482). The profile toggle means: with 1040 known, a webbed, sleeping,
stunned or frozen self casts Troubadour's Rally until clear, pulsing mana first when it cannot
afford it; a group member showing an ailment gets one cast. Now a Cleanse condition, `:rally`,
read before every other affliction (bigshot's call sits before `cmd`), and
`Actions::CleanseRally`: one pulse-and-cast per tick, the engine's re-tick being the until-clear
loop. The toggle is set on `Cleanse::Policy#troubadours_rally` by the script from the bigshot
profile, since ecleanse.yaml has no such key. bigshot's `frozen?` is a name Lich never defines;
`Me#frozen?` answers from Status when it grows one and false until then. The group half is
built with M3 below: `:rally_member` casts once when a group member here shows an ailment
(6720-6724), ten seconds apart, and the wounded-rest hold is Rest's group merge.

## Group: bigshot's head and tail (M3, 2026-09-10)

Read from bigshot 5.16 (`Bigshot::Group` 936-1308, `Event` 763, the head runner 9876-9972,
the tail runner 9973-10216, `lead` 7161, `pre_hunt` 7242, `do_hunt` 7401-7413, `attack`
7780-7797, `rest` 7440-7607, `should_rest?` 9016, `should_hunt?` 8949, `need_to_loot?`
7819-7857, `ma_looter` 7119, `group_all_followers` 9305, `check_for_deaders_prone` 3944-3958,
`find_routine` 7181, `add_overkill` 9060, the MA Grouping settings 3549-3563). Now
`EO::Engine::Group` (Policy, Order, Report, Hub, Leader, Member), `Behaviors::Muster`,
`Behaviors::Orders`, `Behaviors::Assist`, `Behaviors::Follow`, `Actions::GroupOpen`,
`Actions::Disband`, `Actions::LeaveGroup`, `Actions::Join`, and the `group:` seams on Rest,
Loot and Engage; `;eohunter <profile> head <count|names>` and `tail [uri]` in the script.

**bigshot's shape, turned around.** The leader serves a `Bigshot::Group` over DRb; each
follower registers its own `Bigshot` instance in it, and the leader calls those instances for
every question (`ready_to_hunt?`, `looting_inactive?`, `rt?`, `rest_prep_done?`, ...) and pushes
`Event`s onto their stacks, which the tail loop works through. The engine keeps the DRb object
(a `Hub`, served by the leader) and turns the calls around: every tick each follower pushes one
`Report` (the answers to all of those questions at once) and pulls its `Order`s, so the leader
never makes a remote call and cannot be stalled by a follower; a follower's every call to the
Hub is bounded (`Member#remote`, a thread joined on a deadline) and any failure marks the leader
lost. Liveness is the age of the last report: a follower silent for ten seconds is offline,
reported once (`:follower_lost`) and left out of every wait, where bigshot's `member_online`
deletes it. A leader silent for fifteen seconds, or one that has called `leader_finished!`, is a
lost leader and the follower's engine stops with `:leader_lost`. Every order carries the hunt id
and the room and time it was raised in; a follower drops orders from another hunt and an attack
order from another room or older than fifteen seconds (`Event#stale?` 793). The readiness
barrier is the rally: `open_hunt` takes a count or the names, `head` whispers the uri to the
group every three seconds until `ready?` or sixty seconds (9897), then `activate!`; a tail
registers until the hunt is open and waits for it to activate.

**The leader.** `Group::Leader` answers what bigshot's leader asked its Group, from the
reports: `all_present?` (1278, in the room and in the game's group), `looting_done?`,
`roundtime?`, `rest_prep_complete?`, `need_sneaky?`, `rest_reasons` and `not_hunting_reasons`
(1197, 1227), `encumbrance`, and `looter` (`ma_looter` 7119 in its order: the named looter when
in the group, the least encumbered with `random_loot` and the named one on a tie, else the
leader unless on `never_loot`, else a follower at random). It publishes the leader's room,
target, phase and looter every tick (the engine's new `on_tick`), which is what `leader_target?`
(8723) and `room_id` gave the followers on demand. `finish!` broadcasts `:hunt_over` and marks
the leader finished; the script calls it from `before_dying`.

**Rest with a group.** Every wait in bigshot's `rest` and `pre_hunt` is a `:hold` phase: the
test each tick, `follow_now` on entering and again every ten seconds with an unhide (7285)
while it fails. In order: the final loot, then the followers done looting and out of roundtime
(7481); leave with `hunting_scripts_stop` and `prep_rest` to the followers; with
`independent_return` (7493) the followers get `leave_group`, `fog_return`, `go2_waypoints`,
`go2_resting_room` and the leader disbands and waits for the game's group to empty, else
`unhide` and `follow_now` (the pulls of sitting members are Survival's); the fog; a gather after
each waypoint (7526) unless someone is wounded (7531); at the resting room, with
`quiet_followers` (7540) group open, gather, the leader's own prep and scripts, then
`resting_prep` and `resting_scripts_start` to the followers, else the followers' orders first;
then group open and a hold until everyone is present, out of roundtime and prepped (7569);
resting until our own `ready_to_hunt?` and every follower's say ready (`group_should_hunt?`).
Back out: `hunting_prep` to the followers first (7249), our own; with `independent_travel`
(7261) disband, wait for the group to empty, `go2_rally`, else a gather before the rally rooms
(7254) and after each (7270); group open, gather (7281), then `hunting_scripts_start` (and
`go2_hunting_room` when independent) and our own scripts (7292); the hunting room; group open,
`cast_signs`, `check_sneaky` when a sneaky follower is not hidden, and a hold until everyone is
here, hidden and out of roundtime (7315-7341). `should_rest?`'s merge (9016-9040) is
`group_reason`: the followers' reasons with ours, all fried but not everyone keeps hunting, a
wounded rest waits while a member is stunned; a rest for a follower's reason is named
"Bob: fried." and, matching the final-loot reasons, gets the final loot bigshot's leader would
not have made for it.

**Loot with a group.** `need_to_loot?` 7821-7825: only while no follower reports looting;
`looter` picks who, and a follower named gets `prep_rest` and `loot` orders with this room's
corpses marked theirs (7854-7856). The leader's per-corpse bookkeeping orders
`follower_overkill` (9060), which the follower counts as bigshot's `FOLLOWER_OVERKILL` does
(2887, 10100). A follower's Loot runs only when `assign!`ed (10165) and reports `looting?`
until the room is clear.

**Engage with a group.** An `attack` order on a new target and again every ten seconds (7383);
a follower missing from the room or the game's group is called back without stopping the
fight (7786-7792: `follow_now`, group open, unhide, every ten seconds); `disable_commands` is
the routine for a fried member of a group (7181). Between fights `Behaviors::Muster` at
priority 15 holds while a group member is stunned (7401) and calls a missing follower back
before Wander moves on (7406-7413).

**The follower.** The same Survival (never stopping for a deader, 3944), Cleanse, Flee and
Maintain; `Orders` for Rest, `Assist` for Engage, `Follow` for Wander, Loot on assignment.
`Orders` is a Rest subclass driven by the queue instead of the cycle: each order is one of
Rest's steps (prep lists, trips, fog) with the leader's rooms (`return_waypoints_ids` 1110,
`resting_id` 1115, `hunting_id` 1120, `rally_ids` 1125) and the follower's own command and
script lists; `resting_scripts_start` marks the rest prep done (10179); `hunt_over` is acked and
stops the engine; `cast_signs` is a no-op since Maintain casts what is due every tick; `attack`
and `follow_now`, `prep_rest`, `loot` set and clear Assist's latch the way the tail's `:ATTACK`
loop breaks (10118). `Assist` fights only after an attack order and only with the leader in the
room (7794; `should_flee?` 8543 refuses a fight with nobody here, and a follower's flee is
that refusal, not a step), on the leader's target while it stands and its own choice by the
same rules otherwise (10124-10135). `Follow` is `group_all_followers` (9305): not with the
leader, go2 the leader's room; there and not in the group, JOIN; after `leave_group` it travels
on its own orders until the next `follow_now`. The follower reports every tick from its own
Rest policy (`Group.report`) and stops with `:leader_lost` when the Hub stops answering or the
leader's heartbeat is fifteen seconds old.

**Survival with a group.** `group_deader` (3952): a dead group member here holds the leader
the way `deader` does, reported once per room.

**Two things moved for solo too.** The hunting scripts now start after the rally rooms, where
`pre_hunt` starts them (7292); they used to start with the prep commands. A missing or blank
profile key takes its default for every type (3629-3633), booleans included, so `pull`,
`weapon_reaction` and `quiet_followers` default to true when a profile lacks them; before, a
missing boolean read as false. `troubadours_rally` was read without a RULES entry and so was
always off; it has one now.

**Built with the bounty child (below).** The bounty state in the report, the roster verdict, and
the acknowledged shutdown. The nine failure cases remain live acceptance. The rally whisper is
"eohunter rallying at druby://host:port"; bigshot's tails will not answer it and eohunter's will
not answer bigshot's.

## Bounty child mode (M4, 2026-09-10)

Read from bigshot 5.16 (the bounty option 3355-3361, `set_bounty_eval` 3823, `bounty_check?`
8899, its call after every command set 7862, the exits at 7458, 7578 and 8952,
`set_bandit_hunting` 6888) and ebounty 1.11.2 (`go_hunting` 2234-2295, `set_eval` 2078,
`over_watch` 431, `switch_profile` 703). Now the `bounty` word in eohunter.lic and, in group.rb,
`Group.bounty_state`, `Leader#verdict` and `Leader#end_hunt`.

**What ebounty does before the child starts.** It loads the creature's bigshot profile into
`UserVars.op`, rewrites `targets` (the bounty creature alone with `only_required_creatures`, the
bandit nouns added for a bandit task), sets the bandit location's `hunting_room_id`,
`rallypoint_room_ids`, `hunting_boundaries` and `wander_wait`, and writes `bounty_eval`, a Ruby
expression over `checkbounty`, `checkmind`, `@CORRECT_PERCENT_MIND`, `$bigshot_bandits` and
its own container counts. Then it runs `bigshot bounty` (or `bounty <creature>` for
`ranger_track`) and waits for the child to die. The engine changes none of that.

**The child.** `;eohunter bounty` builds the engine from `UserVars.op` through the same
`Profile` (no YAML read), turns the `<creature>` word into Ranger tracking, sets
`$bigshot_bandits` from the bounty text and lets `Tracking.policy_from` switch bandit mode on
from it. Every two seconds it evaluates `bounty_eval` in the script's binding with
`@CORRECT_PERCENT_MIND` set to the field experience percent, bigshot's default expression
standing in when ebounty left none; not while a bandit is still in the room (8901). True is a
forced rest, "Bounty should be complete/ready" (7862-7864). Rest goes home and preps, and
emits `:rested` at the resting room, where the child stops with `:bounty_rest`: bigshot's
7578 exit in bounty mode with ebounty running. A rescue task whose child is here ends it at
once (7458). ebounty then does the town and starts the next child.

**With a group.** Each follower's report carries `Group.bounty_state` from its own Lich task
(`:none`, `:hunting`, `:complete`, `:failed`; terminal states stick on the leader). The leader
asks `verdict` on every check: a follower gone quiet is `:member_lost` before anything else and
stops the child; `:bounty_complete` only when the leader's own eval is true and every follower
is complete, failed or off a bounty, and that is the forced rest. A follower whose task is done
keeps assisting. `end_hunt` from the leader's `before_dying` broadcasts `hunt_over`, waits up to
fifteen seconds for every ack, and records the exit with who never answered. The follower's
own ebounty for the town phases is ebounty's change, not the engine's.

## Core only (2026-09-10)

With the nine lich-5 PRs in the runtime (the eohunter test package), the
engine dropped its three remaining copies of core, per the core consumption
audit (`core-consumption-audit.md`):

- **The send ladder.** `Actions::Base#send_through_ladder` is `fput` with
  `max_resends: 5, timeout: 30, interrupt:, resend_transient: true,
  failures: :symbol` (#1587); a Symbol back is a failed Result of that
  reason, a String is the answer line left in the buffer for the
  confirmation step. `settle_rt` is `waitrt?` and, for CombatRt actions,
  `waitcastrt?`, each `interrupt:` and `cap: 15`. The three confirmation
  shapes stay: they are the engine's contract, not fput's.
- **The watch.** `Watch.install!` enables the tracker with `emit_attacks`
  and subscribes once to every `Combat::Messages` event (#1586), to `:ucs`
  and to `:attack`. `Watch.message` renames `:item_limit` to
  `:too_many_items`, maps the hive trap kinds to ecleanse's, adds the
  hands and room to a disarm and `mine` to a shrugged bless; `Watch.ucs`
  emits `:unarmed_tier` and `:unarmed_followup`; `Watch.attack` emits
  `:incoming_swing` for an inbound attack and `:force_roll` per resolution
  of our own. The DownstreamHook exists only when a profile has a
  `flee_message`.
- **Fog.** `Rest::Fog.return` is `Lich::Gemstone::Fog.return` (#1584);
  libeo is not loaded.

The script checks for Fog, Combat::Messages, Stance and Mana at start
and refuses with the package's address when any is missing.

## Edge-case checklist (M1 acceptance)

Each is a behaviour bigshot has that eohunter must reproduce, with where it lives in bigshot 5.16
for the port. Ported deliberately, one at a time, with a spec or a replay each.

- Fog return: voln, spirit, custom, `fog_optional`, `fog_rift` (`fog_return*`)
- Escape rooms: Belly of the Beast, Ooze innards, Duskruin sands, Temporal Rift (`escape_rooms`, `creature_escape`, `temporal_escape`)
- Swallowed by roa'ter / ooze mid-attack (`escape_rooms` after every command set)
- Ambusher detection and `$ambusher_here` semantics (`hunt_monitor`)
- Bandit tracking and manufacture of the quarry from a look (`bandit_track`); ranger tracking (`ranger_track`) - done, "Bandits and tracking"
- Briar Betrayer blood and bow raise (Forge has this already for the arena)
- Wand and ammo state machines (`cmd_wand`, `cmd_wandolier`, `cmd_recover`, `cmd_dislodge`, `hide_for_ammo`)
- Mstrike stamina ladder and quickstrike sizing (Forge has a first version)
- UAC tiers, smite, followups (`cmd_unarmed`, `assess_followup`, `tier3`)
- Sneaky hunting and `movement autosneak` cleanup (`sneaky_hunt?`, teardown)
- Troubadour's rally on group ailments (`group_status_ailments`) - done, "Troubadour's Rally" and "Group"
- Bless and item display (`cmd_bless`, `display_items_for_blessing`)
- Weapon reaction (`perform_reaction`)
- Dead man switch and depart switch as Survival policy, not threads (`dead_man_switch`)
- Interaction monitor as a bus subscriber (`monitor_interaction`)
- Loot policy: delay, random, never, final, box in hand, disks and `ignore_disks`, claim check, group looting done (`need_to_loot?`, `loot`, `looting_watch` including the pause race fix from #2433)
- Deader, pull, priority retarget mid-fight (#2395), lone targets, invalid targets, appendage nouns, animated decoys, boon spawns and boon flee (`valid_target?`, `sort_npcs`, `priority`, `check_boons`)
- Fried / overkill / LTE boost accounting (`add_overkill`, `use_lte_boost`, `check_mind`)
- Creeping and crushing dread, wall of thorns poison, confusion (`ready_to_rest?` predicates)
- Wracking spirit (`wrack`)
- Stance dance and perfect stance (`change_stance`, `cmd` stance handling)
- Cast taxonomy: self-cast detection, blocked, hindrance, success, `caststop`, resonance bolt rotation, mana pulse (`cast_spell`, `cmd_spell`, `cmd_resonance_bolt`, `mana_pulse`)
- Roundtime and transient-blocker resend ladder (`bs_put`)
- Once-per-target command registry (`once_commands_register`)
- Independent travel and return for followers, quiet followers, group deader, MA looter selection (`ma_looter`, `designated_looter`, `group_all_followers`) - done, "Group"; live runs pending
- Coup de grace eligibility gate, `empowered<N>`, `thp<N>` (#2451)
- Everything in the crtrStatus migration from #2414 / #2415, which the engine gets for free from World and Creature
- ecleanse's twelve conditions: weapon knocked away (four messagings), telekinetic loss, webbing on weapon, web-bound, hive trap apparatus and ground, itchy curse, infected wound / vat, sanctum transform, plus dispel / unpoison / undisease / stun / avoid webs / globe / runestone (`set_hooks`, `Action` module)

## Risks and open decisions

- **Lich dependency and review latency.** libeoengine and eohunter need P1, P2, and the same
  Lich 5.21 prerelease the bigshot stack does. libeo.lic and libeosettings.lic must not, so
  existing scripts can adopt them on released Lich; the forwarding shims are how. Two lich-5 PRs
  sit on the critical path before the spike; if review stalls, the shims let L1 and L2 proceed
  on a local lich-5 branch and the PRs land later.
- **Library versioning across the e-scripts.** Five scripts on one library means one bad release
  breaks five scripts. Mitigations: each script pins the `EO::VERSION` it was built against and
  the library refuses a mismatch; the util layer is additive-only after L1 (new helpers, never
  changed signatures); the release note says which scripts moved.
- **Parity is the real cost.** About fifty checklist items, each a port, a spec, and a live
  provocation. M1 assumes one to two per day. The recorder and replay are how eohunter catches
  up on years of hunting-ground-specific fixes without re-living each one.
- **Two engines during transition.** Users will run both. The profile is shared, so a profile
  edit helps both, but a behaviour difference will be reported as a bug in whichever they didn't
  expect. eohunter prints its name on every start and in every status line.
- **The routine compiler rejects at load.** Profiles with typos in modifiers that bigshot
  silently ignored will refuse to load. A feature, and support noise.
- **Community.** horibu maintains bigshot; therealatari is building Quick; Tysong wanted the
  split. This plan asks none of them to change what they are doing. It does mean the MA work
  that was going into bshead and bstail goes into eohunter, and that the e-scripts gain a
  library dependency their authors didn't ask for. Both should be said plainly, and the library
  should land as a PR the e-script maintainers review before any script depends on it. The
  lich-5 PRs need the same conversation with lich's maintainers, and the tracker's persistent
  enable is worth raising with horibu at the same time.

## Effort

| Milestone | Estimate |
|---|---|
| P1 lich-5 helpers PR | two or three days plus review |
| L1 libeo util | three days, overlapping P1 |
| P2 lich-5 parser seam PR | two weeks plus review |
| L2 libeoengine | a week |
| M0 spike | a week |
| M1 solo parity incl. Cleanse | four to five weeks |
| L3 libeosettings | a week, any time after M1 |
| M3 group | two weeks |
| M4 bounty objective | three weeks |
| M5 cutover | a week |

Fourteen to sixteen weeks part-time with two test characters on the prerelease, plus lich-5
review latency on the two PRs, which is on the critical path before the spike. The first three
weeks produce something every script can use whether or not eohunter ever ships, and P2 is
the piece bigshot and Forge benefit from directly.
