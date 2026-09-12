# Troubleshooting

What the engine prints, what each stop means, and what to collect when
reporting.

## The lines

Every decision is an `eohunter:` line. The ones worth knowing:

| Line | Meaning |
|---|---|
| `hunting: survival, cleanse, ...` | the engine started with these behaviors |
| `engaging <name> (routine a)` | Engage took a target and which routine it will run |
| `resting: <reason>` | Rest decided to go home; the reason is the profile rule that fired (fried, oom, encumbered, wounded, a follower's reason) |
| `fleeing: <reason>` | Flee is leaving: the count, a name, a message, a hazard, an ambusher |
| `cleanse: <reason>` | Cleanse is treating something |
| `DISARMED: <noun> in room <id>` | the disarm was seen; Cleanse's recovery runs |
| `loadout <wanted>: <reason>` | the configured hunting hands could not be restored; a solo hunt or leader returns to rest before stopping |
| `could not reach <room>` | five go2 attempts at a room failed; on the way home Rest waits a minute and tries again, `trying <room> again (n of 3)` |
| `stranded: could not reach <room> from <here>` | three rounds failed; Rest preps and rests where it stands, and does not report `rested:` (the bounty child does not exit) |
| `watchdog: <kind> in <behavior> (<count>)` | the engine stopped itself; see below |
| `stopped: <reason>` | the engine ended and why |
| `<Error>: <message>` with frames | an exception in the engine; the frames are the engine's own |

## Stops

**`watchdog: repeated_failures in <behavior> (5): <reason>`.** Five
commands in a row went to the game and were refused or never answered:
a target that is not there, a command the character cannot do, a
container that does not open. The reason after the count is what the
last one answered, and the line under it is the game's own words when
the action read one, so the stop usually names its own cause. The line
after that says which behaviors above it declined the tick, so you can
tell "Engage kept swinging" from "Rest could not walk".

A tick the character simply could not act on does not count here.
Being stunned or webbed, a technique on cooldown, too little stamina,
a target that died while roundtime ran: those are skipped, not failed,
because nothing was sent. If the hunt stops with this line, a command
really did go out five times and the game really did refuse it.

**`watchdog: fire_budget in <behavior> (61)`.** A behavior put more
than sixty commands on the wire in a minute, faster than roundtime
allows a real action. It was looping on successes: a retarget that
never lands, a search that never clears, a stance flip. Only commands
the game actually received count: a routine line the behavior refused
itself (a spell gate, a stance it was already in) is not a fire,
whatever status it reported. The declining behaviors are printed as
above.

**`stopped: dead`.** Death, with `dead_man_switch` and `depart_switch`
off. **`stopped: deader`.** A dead player in the room during the hunt
with `deader` on. **`stopped: leader_lost` / `member_lost`.** The group
link went quiet past its deadline. **`stopped: engine_error`.** An
exception; the message and frames are printed.

**`eohunter: this Lich lacks <constant>`.** The Lich running has none
of the core PRs the engine needs. Install the test package; see
[Core dependencies](core-dependencies.md).

**`stopped: loadout_stuck`.** The configured item was missing,
inaccessible, invalid for both hands, or did not reach the requested
hand. The preceding `loadout ...` line gives the exact desired state
and Lich::Stash error. Resolve the inventory or ReadyList entry before
restarting. The failure is attempted once per hunt, then requests the
existing return lifecycle. Followers use the leader's resting room;
a solo profile without one stops with the diagnostic where it is.

## Reading a line number

If you are running the built single file and an error names a line,
`dist/eohunter.lic.map` (attached to the release beside the script)
says which part that line is in. Subtract the part's first line to get
the line within the part.

## Common causes

- **A room did not resolve.** `dry` prints the hunting room and the
  boundaries; a blank one means the id or `u<uid>` in the profile is not
  in your map. The resting room is not in the report, so check it in the
  profile directly. Fix the profile, not the engine.
- **Every routine line is skipped.** A modifier is vetoing all of them.
  `dry` prints the compiled routine with its modifiers; check for a
  `!` that is inverted, or a buff word whose buff name changed.
- **The hunt never starts.** Wander wants the claim to be ours; in a
  shared area another hunter's claim makes it wait. Survival or Cleanse
  may be holding the tick: a stun, a web, a hazard in the room.
- **Loot never happens.** The looter in a group is the leader's
  `ma_looter`; a follower loots only when told. `delay_loot` waits
  fifteen seconds after the kill.
- **A creature is never attacked.** It is not in `targets`, or it is in
  `invalid_targets` or CharSettings' untargetable list, or an ASSESS
  matched `boons_ignore`, or Lich's GameObj.targets excludes it (dead,
  an appendage, an animated decoy).

## Reporting

The useful things: the `eohunter:` lines around the problem, the game
text just before it, your profile name, and the Lich version line from
`;version`. For a group problem, the leader's and the follower's lines
both. Report to Nisugi, or open an issue on the repo with those pasted.
