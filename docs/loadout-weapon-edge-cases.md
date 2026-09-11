# Loadout PR addendum: weapon ownership and combat transitions

Status: local review and proposed acceptance criteria; not posted to the PR.
Reviewed 2026-09-12. No live combat was executed for this review.

Implementation follow-up: this report records the original reviewed revision.
The extension in `loadout-extension-plan.md` fixes the target-switch defect and
adds named sets and bounded managed-throw recovery. See the current guides and
regression tests for implemented behavior; this historical finding is not a
claim that the defect remains in the updated branch. Replacement-ID returns and
custom generated-projectile scripts remain unsupported and fail explicitly.

PR: https://github.com/Nisugi/hunter/pull/74

Pinned comparison: `07b9ee705ba251b091c0d9547f6e6cb3cde0940f...ce2633aa50959b8734cfab7a2c3789c5540ee284`.

The existing proposal restores an optional hunting-hand baseline through Lich
Stash while allowing active routines to own temporary equipment. This addendum
examines where that ownership begins and ends. It does not propose a second
inventory system, a new creature classifier, or automatic equipment selection.

## Standards

No additional documented-standard violation or material architecture smell was
found in the scoped weapon paths. Loadout delegates movement to
`Lich::Stash.hands` (`scripts/eohunter/loadout.rb:145`), consistent with the core
consumption rule in `docs/guides/architecture.md`. Its adapter and resolved-ID
cache have concrete responsibilities; a separate generic weapon manager is not
justified by this review.

Verification gaps remain around real conditional swaps, simultaneous targets,
Assist, and delayed weapon return. These are not claims that this PR introduced
the existing throwing implementation.

## Spec

### Confirmed: priority target changes bypass baseline restoration

The originating plan requires reconciliation before Engage takes a new target.
`Engage#owns_hands?` (`scripts/eohunter/engage.rb:888`) grants ownership while the
previous target is alive. However, target selection can prefer a newcomer
(`scripts/eohunter/targets.rb:326`), and Engage immediately switches its routine
(`scripts/eohunter/engage.rb:925`). The previous target's temporary equipment can
therefore reach the first attack against the new target.

An offline reproduction uses the real Engine, Engage, and Loadout arbitration
with simulated inventory and routine hand mutations. An orc routine equips a
maul; a higher-priority kobold arrives; the kobold receives an attack with the
maul instead of the configured staff. The expected-contract test fails. Two
additional characterizations pass, covering routine ownership until despawn and
the delayed-return failure latch. Parent rerun: three examples, one failure.

Assist changing its selected target while the old target lives needs equivalent
coverage; that path was identified by inspection, not independently reproduced.

### Delayed return: integration risk, not a verified live regression

Plain `hurl` uses `Actions::Attack`, which returns after initiation
(`scripts/eohunter/combat.rb:89`). Target death/despawn releases Loadout ownership.
If the baseline weapon is still airborne and Stash cannot resolve it, Loadout
can latch equipment failure (`scripts/eohunter/loadout.rb:260`). A simulated
missing-item result confirms that later hand restoration and a `bond_return`
event do not clear this terminal latch. Real return timing and real Stash
resolution in that interval have not been verified.

Distinguish `dhurl`: it calls `RecoverHurl` synchronously before its action
returns (`scripts/eohunter/routines.rb:561`, `:611`). Loadout does not interleave
inside that successful recovery. Lich already emits `:bond_return`, forwarded by
Watch and consumed by Engage; reuse these mechanisms rather than adding another
message parser or an arbitrary sleep. The event does not establish support for
every scripted returning weapon.

### Conditional weapon selection is separate scope

The original plan excludes automatic target-specific loadouts. Existing routine
conditions such as `(undead)` and `(noncorporeal)`, plus Wield/Store, are the first
integration surface to test. Preserve intentional routine swaps. Do not infer
blessing, sanctification, or attack eligibility from an item name, and do not
introduce another creature classifier. Named per-target sets would require a
separate explicit design decision.

## Proposed acceptance matrix

| Scenario | Required result |
| --- | --- |
| Multi-step routine changes weapons against the same live target | No baseline restoration between its dependent steps. |
| Priority or Assist switches targets while the old target lives | Explicit equipment handoff before the new target's first attack; no inherited temporary weapon by accident. |
| Ordinary throw, target survives | Existing throw/recovery behavior retains the required equipment ownership. |
| Killing throw or target despawns before automatic return | Pending return is distinguished from confirmed equipment loss; no premature missing-item latch. |
| Temporary thrown weapon returns, baseline is another weapon | No baseline item occupies its required return hand prematurely; baseline follows completed cleanup. |
| Return overlaps Loot, skinning, or another temporary hand operation | One owner controls hand changes; cleanup completes before reconciliation. |
| Return fails or no hand is free | Bounded existing recovery with an explicit outcome, not an endless wait or silent substitution. |
| Hold, stop, danger, or retreat occurs during recovery | Survival and travel retain priority; unresolved equipment is reported without an unsafe chase. |
| Actual disarm rather than intentional throw | Consume existing combat events and recovery behavior; do not classify every empty hand as disarm. |
| Living/undead/noncorporeal routine-controlled sets | Correct conditional routine runs, remains undisturbed, and hands off safely at target changes. |
| Returned/transformed item keeps its ID but changes name | Identity caching does not trigger unnecessary movement. |
| Return produces a replacement ID | Core resolution refreshes identity or reports an explicit unresolved outcome. |
| Optional baseline is unset / `keep` | Existing unmanaged-hand behavior stays unchanged. |

Any adjustment should make the target-selection handoff explicit and reuse the
existing recovery owners. Target liveness alone is insufficient to prove that
equipment cleanup is finished. Do not add a broad ownership framework before
these concrete callers demonstrate that it is necessary.

The separate local Lich Stash permanent-displacement fix prevents stale
empty/fill restoration frames. It does not solve pending thrown-weapon return
or target-switch ownership, and must not be described as doing so.

## Disposition

Address the reproduced target-switch defect before calling the original
baseline contract complete. Add focused tests for the throwing paths before
claiming general hurler compatibility. Keep automatic per-creature set
selection outside this PR unless maintainers explicitly expand its scope.

Review totals: Standards — 0 hard findings; Spec — 1 confirmed defect, plus
explicit integration-test gaps and proposed new acceptance criteria.
