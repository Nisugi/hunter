# Combat buff policy (opt-in)

Hunter can require selected beneficial spells, restore native spells in place,
or return to a configured refuge for a spell-up. It consumes Lich's `Spell` and
`Effects` observations. It does not parse new game messages or maintain its own
spell-duration table. Cleanse still owns harmful effects; EWaggle is a spell-up
executor, not a monitor.

## Configuration

Add `combat_buffs` to a hunting profile. Omitting it, or setting `enabled: false`,
preserves existing maintenance and rest behavior. This release supports ordinary
solo hunting. Group, bounty and LAB-controller modes reject enabled policies
before actions: their return/termination contracts need separate integration.

```yaml
combat_buffs:
  enabled: true
  default_action: field
  on_failure: field
  max_attempts: 2
  verify_seconds: 3
  recovery_seconds: 15
  spells:
    406:
      action: recast
      on_failure: field
    911: warn
    219: {}             # inherits field; required before departure
    117: ignore        # deliberately consumed; do not restore automatically
```

| Setting | Meaning |
| --- | --- |
| `enabled` | Explicit boolean; defaults to false. |
| `spells` | Spell number to rule mapping. Only these spells are monitored. |
| `default_action` | Default response for entries without `action`; defaults to `field`. |
| `action: recast` | Restore a native known/affordable spell through Maintain's existing gates and casting action. |
| `action: field` | Request field rest, or town if no field refuge is configured. |
| `action: town` | Request town rest; outranks simultaneous field requests. |
| `action: warn` | Report the missing spell without requiring recovery or blocking departure. |
| `action: ignore` | Do nothing; also overrides this spell in the legacy `signs` list. |
| `required` | For recast/field/town rules, defaults to true. When true, missing effects prohibit departure. Warn/ignore cannot be required. |
| `on_failure` | Field or town when native restoration is unavailable or unconfirmed; per-spell overrides the default. |
| `max_attempts` | 1-3 maintenance attempts per continuous loss episode, default 2. Existing casting actions retain their internal retry semantics. |
| `verify_seconds` | 1-60 seconds to observe the effect after each restoration attempt, default 3. No rapid retry loop. |
| `recovery_seconds` | 1-60 seconds to verify required buffs at the departure gate after recovery work, default 15. |
| `mana_spellup_at` | Default 0 (disabled), or 2-100 missing native recast buffs to try `MANA SPELLUP` before individual casts. |

Bulk spell-up is separately opt-in because it spends a limited daily use and can
activate unlisted buffs, including trade-off spells. It is scheduled through the
existing command action, never during an owned loot operation or active travel.
There is at most one attempt per loss episode. Verified restoration permits a
new attempt on a later qualifying loss. Before each attempt a bounded `MANA`
query must report remaining daily uses. The query and spell-up each take their
own scheduled action slot. Zero remaining uses, unrecognized output, or a query
timeout select individual recasting, with negative results cached for 60 seconds
to avoid polling. A positive count expires after five seconds and is invalidated
as soon as a spell-up is attempted; later losses obtain fresh counts. This avoids
assuming yesterday's exhaustion persists after a reset.

If any selected effect remains missing
after `verify_seconds`, Hunter disables bulk for the remainder of that run and
individually restores what is still missing. This includes exhausted daily uses,
refusals, and partial restoration; it does not claim to distinguish their causes.
Restarting Hunter resets this conservative bulk-failure latch. Dispatch alone
never proves success. The bulk attempt does not
spend individual retry allowances. It can be attempted without enough mana for
individual casts, but cannot replace unknown spells or bypass explicit return
rules. A small temporary query adapter reads the game's reported used/total
counts; it does not calculate allowances from training or predict daily resets.
This adapter should consume core observations once Lich exposes them.

Unknown fields, invalid spell-number syntax, duplicate IDs and contradictory
settings are rejected. A valid positive town `resting_room_id` is mandatory.
Missing Lich spell definitions are treated as unavailable, not permission to cast.
Native restoration also requires core metadata identifying a timed, non-attack,
non-timer effect; casts explicitly target self. Special signs-list commands
(aspects, weapon blessings, maneuvers) are not handled by the new recast path.

## Recovery ownership

The existing `resting_scripts` and `field_rest_scripts` choose what runs at each
site. Put EWaggle in the appropriate list if desired; this feature never inserts
scripts or changes their configuration automatically. An external spell such as
219 cannot be supplied by a character's native EWaggle unless they actually have
a suitable source. Arrange external restoration yourself; absent charges or an
unavailable provider do not authorize purchases, scroll consumption or commands.

Maintain performs native restoration only when scheduled. Rest requests use the
existing travel/stance lifecycle and wait for owned looting to finish. Survival,
Cleanse and Flee retain higher priority. Required buffs are checked on the first
departure as well as after subsequent recovery. If needed, initial departure
runs one recovery pass through the configured rest scripts.

A successful cast return or script exit does **not** prove the spell exists.
The player must be at the selected refuge and the required effects must actually
be observed before departure. If verification times out, the existing
`rest_service_failed` handoff stops the hunt there with the missing spell IDs.
It does not repeatedly rerun EWaggle or leave and return in a loop. Correct the
spell source/profile and restart the hunt after addressing that failure.

Policy messages show spell IDs and states (`recast`, `spellup_check`, `spellup`, `pending`, `field`, `town`,
`warn`) when the assessment changes; unchanged loss states are not spammed.
No distinction between expiry and dispelling is inferred from disappearance.

## Deliberate scope

- Explicit spell lists only: no automatic capture of everything active on login.
  Consumed buffs, short bursts, cooldowns and region-stripped external effects
  make that unsafe without additional policy. Do not require Rift-stripped
  effects in a Rift profile.
- This is missing-effect management, not proactive duration extension.
- Native player buffs only for `recast`; weapon blessings, aspects, maneuvers,
  scrolls and item use are not new restoration providers in this patch.
- No new GUI, independent watcher, background command loop or Lich core parser.
- No automatic group support, LAB action authority or changes to existing profiles.

## Smoke test (player-supervised)

1. Use a copy of a profile and a verified safe room. Run `eohunter PROFILE dry`
   first. Ensure the field/town paths and spell-up scripts are already tested.
2. Monitor a native defensive spell with `recast`; remove it deliberately and
   verify one scheduled restoration, followed by an observed active effect.
3. Make an optional entry `warn`; remove it and verify there is no retreat.
4. Make a required entry `field`; remove it in a low-risk hunting room and
   verify return, configured spell-up, observed restoration, then departure.
5. At refuge, use a deliberately unavailable required spell to verify a bounded
   safe failure, with no departure or repeated spell-up loop.
6. Check loss during owned looting and with simultaneous town-service needs.
   End the test at the verified refuge with the correct equipment restored.
