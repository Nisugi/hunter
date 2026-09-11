# Core consumption audit (2026-09-11)

Doug's criterion: what share of a script's work is done by Lich's own
methods, modules and classes, rather than copies of them. This is the
engine measured against it, file by file: what consumes core today, what
duplicates it, and for each duplicate the move (a core PR, an adoption, a
deletion, or a keep with the reason). Line counts are from the tree at
07b9ee7.

The group decides what goes into core. This document is the list to
decide from.

## The score today

| File | Lines | Consumes | Duplicates |
|---|---|---|---|
| actions.rb | 305 | `put`, `get?`, `clear`, `Script#downstream_buffer` | the refusal ladder (fput), `dothistimeout`, `waitrt?` |
| combat.rb | 269 | `Spell#cast` / `force_cast` / `force_channel` / `force_evoke` / `force_incant`, `Spell#known?` / `affordable?` | the cast answer table (bigshot's) |
| maneuvers.rb | 451 | the PSM readers (`CMan`, `Weapon`, `Shield`, `Feat`, `Warcry`: `known?`, `available?`, `affordable?`, `buff_active?`, `command`, `results_regex`, #1583) | nothing |
| routines.rb | 1789 | `Lich::Util.issue_command`, `quiet_command_xml`, `Lich::Stash.equip_hands`, `CMan.available?` | raw sends where core has none (below) |
| cleanse.rb | 1689 | `CMan.known?` / `available?` / `use`, `Feat.available?`, `Stance.change`, `Stash.equip_hands`, `issue_command` | `mana_pulse` (Mana.pulse, #1580), `wait_rt`, `stand_up` |
| world.rb | 927 | `XMLData`, `GameObj`, `Status`, `Effects`, `Map`, `Char`, `Stats`, `Skills`, `Experience`, `Creature`, `Claim`, `Disk`, `Group`, `Bounty`, `Spell` | one private ivar read; about 190 lines of Forge leftovers no behavior calls |
| rest.rb | 964 | `Lich::Gemstone::Fog.return` (#1584), `Stance.change`, `Script` | nothing |
| travel.rb | 270 | the go2 script, `Script.start` / `running?` / `kill` | nothing |
| watch.rb | 228 | `Combat::Messages` and the `:ucs` / `:attack` subscriptions (#1586), `DownstreamHook` for the profile's flee text | nothing: the rules are core's now |
| group.rb | 1531 | `DRb`, `Group.members` / `leader`, `Disk` | nothing in core to consume |
| profile.rb | 288 | none | bigshot's `load_settings` / `clean_value` (script-level, not core) |
| controller.rb | 872 | `Script` child lifecycle and execution guards, `XMLData`, `GameObj`, `Room`, `Creature`, `Overwatch` | nothing; the LAB seam has no core equivalent |
| tracking.rb, targets.rb, flee.rb, wander.rb, loot.rb, maintain.rb, survival.rb, engage.rb | ~4035 | `Stance`, `GameObj.targets`, `Creature`, `Effects` | the rules themselves are bigshot's; nothing is core's |

Every send in the engine goes through one of four places: the ladder in
actions.rb, `Spell#cast`, the PSM readers, or `Lich::Util.issue_command`.
The rules (when to rest, whom to fight, when to flee) are bigshot's and
have no core equivalent; they are what the script is.

## 1. The send ladder (actions.rb 114-175): a core PR

`Base#send_through_ladder` is `fput` (global_defs.rb 1643-1720) rung for
rung, with the same three regexes for a roundtime refusal, a "struggle to
stand" and a transient refusal. What it adds, and why it was written:

| | fput | the ladder |
|---|---|---|
| "...wait N" | sleeps N, resends, no cap | sleeps N, resends, capped at 5 |
| "struggle to stand" | `fput 'stand'`, resends, no cap | the same, capped |
| transient (stunned, can't seem, don't seem) | waits out stunned or webbed, else gives up (`false`) | waits out stunned or webbed, else resends after 0.25 s (bigshot's `bs_put`), capped |
| no answer at all | 60 s, then `false` | 30 s, then a Result |
| the engine's stop | none | checked on every wait |
| dead mid-wait | echoes and returns `false` | a Result the caller handles |

`send_and_match` (253) is `dothistimeout` (global_defs.rb 2029) plus the
interrupt and the dead check. `settle_rt` (203) is `waitrt?` /
`waitcastrt?` with a 15 s cap and the interrupt.

**The move.** One PR to lich-5 adding what the ladder has and fput lacks,
as keyword options on the existing methods rather than a parallel method:
`fput(cmd, max_resends:, timeout:, interrupt:)` returning the first
non-refusal line or a symbol naming the failure (`:too_many_resends`,
`:no_response`, `:interrupted`, `:dead`) instead of a bare `false`;
`dothistimeout` and `waitrt?` taking the same `interrupt:`. Defaults keep
today's behaviour so no script changes. Then actions.rb's ladder becomes
`fput(command, max_resends: 5, timeout: 30, interrupt: @interrupt)`,
`send_and_match` becomes `dothistimeout`, `settle_rt` becomes `waitrt?`,
and about 110 lines go. The one behavioural difference to settle in
review: fput gives up on a transient refusal, bigshot and the ladder
resend after a quarter second. The ladder's cap is what makes the resend
safe; the PR should carry the resend under the cap.

## 2. Watch rules: adopt #1586

Of the 39 rules in the engine's `Watch`:

- **35 are `Combat::Messages` events** as of #1586, same event names,
  same payload keys. Each `Watch.on(...)` becomes
  `Combat::Tracker.on(:event) { |_t, d| Events.emit(:event, d) }` in the
  part that owns it, and the rule text is deleted.
- **2 are already `:ucs` facts** (the positioning tier, the followup
  attack): subscribe to `:ucs` and read `kind`.
- **1 is the attack parser's inbound flag** (`:incoming_swing`): subscribe
  to `:attack` with `emit_attacks` on, or ask for a lighter `:inbound`
  fact in a follow-up to #1586.
- **1 stays** (`flee_message`, the profile's own text).

After that, watch.rb is a bus adapter of about 20 lines or goes entirely.
This is the single largest reduction available: about 60 lines of regex
and the engine's only DownstreamHook.

## 3. cleanse.rb helpers: adopt

- `CleanseHelpers#mana_pulse` (314) is `Lich::Gemstone::Mana.pulse` (#1580),
  which the Cleanse rally already uses. Replace the helper.
- `CleanseHelpers#wait_rt` (335) is `settle_rt` with two sleeps around it,
  ecleanse's habit. Delete; call `settle_rt`.
- `CleanseHelpers#stand_up` (341) is `Actions::Stand` without the stance
  handling. Delete; use the action.
- `CleanseRetreat` sends `target clear`, `cman retreat`, `target #id`
  raw (442-444); `CMan.use('retreat')` through the reader would give the
  result regex for free.

## 4. world.rb: delete the leftovers, one small core PR

The facade is 146 methods; 140 of them are one-line delegations, which
is what a spec seam should be. The rest:

- **Forge leftovers no behavior calls** (about 190 lines): `snapshot`,
  `creature_state`, `crtr_status_seen?`, `transit_wait_seconds`,
  `route_distances`, `distances_from`, `path_to`, and the whole creature
  name matcher in `RoomView` (`match_key`, `variant_key_match?`,
  `gender_folded`, `boon_prefix_match?`, `same_creature?`,
  `targets_named`, `known_creatures`). They came in with the Forge copy
  for the campaign runner and the recorder. Delete them; the specs that
  cover them go too.
- **One private read**: `crtr_status_seen?` reads `@crtr_flags` off a
  `CreatureInstance`. If it is kept, that is a one-method core PR
  (`CreatureInstance#crtr_status_seen?`). If the leftovers go, it goes
  with them.
- **`Me#debuff_level`** parses "(N)" out of a debuff name. Core's
  `Effects::Debuffs` could answer the level; small PR, low priority.
- **`Me#frozen?`** exists because bigshot calls a `frozen?` Lich never
  defined. Keep the shim until Status grows one.

## 5. routines.rb: raw sends with no core home

The routine words send raw where core has no method: `sheath`, `gird`,
`store <hand>`, `reserve`, `rub my <container>` (the wand reserve
machinery), `aim <part>`, `raise #id`, `open my #id` / `put #id in my #id`
for the disarm recovery, the 650 `prep` / `cast` pair for Assume Aspect.
Each goes through the ladder, so they are verified, not fire-and-hope.
Two are candidates for `Lich::Stash`: storing a hand and the open-and-put
into a named container (ecleanse and eloot do the same by hand). The rest
are bigshot's vocabulary and belong where they are.

## 6. Not core's

- **The rules.** Targets, flee, rest, loot, maintain, engage, wander,
  tracking: bigshot's decisions, read from its lines. Nothing in Lich
  decides when to rest.
- **Group** (640 lines). Lich has `Group` for the game's roster and no
  cross-process layer. The Hub is a candidate for libeo when a second
  script needs it (ebounty's group bounties are the first candidate).
- **Travel.** go2 is a script; the supervision of it is the engine's.
- **Profile.** bigshot's profile format is a script format. A shared
  reader belongs in the e-scripts (bsprofiles owns the editor) not in
  Lich.

## Order and size

| Move | Lines out of the engine | Where |
|---|---|---|
| Adopt #1586 for the watch rules | ~60 | done: watch.rb is the subscription bridge; the engine needs the test package |
| Delete the Forge leftovers in world.rb | ~190 | done, 4edaf6c |
| cleanse helpers to Mana.pulse / settle_rt / Actions::Stand | ~30 | done, 4edaf6c |
| fput / dothistimeout / waitrt? options PR, then adopt | ~110 | done: lich-5 #1587 open, the ladder is fput's; the engine needs the test package |
| Stash: store a hand, put into a named container | ~20 | lich-5 PR (#1579 follow-up), then engine |
| Effects debuff level, CreatureInstance crtr seen | ~10 | lich-5, low priority |

The first three need no review from anyone and take about 280 lines out
of the engine. The fput PR is the one that matters to
the group's criterion, since it is the copy Doug and ATARI both named.
