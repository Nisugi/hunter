# Named equipment sets and safe combat handoffs

Status: implemented and independently reviewed, extending loadout PR #74. GUI work is
explicitly deferred; profiles remain YAML. No live character testing or
deployment is authorized by this implementation step.

## Contract

Keep `hunting_right_hand` / `hunting_left_hand` as the default baseline. Profiles
without managed hands or named-set rules must retain their existing behavior.

Add `hunting_loadout_sets`, a map from user-chosen names to right/left hand
requirements. Requirements reuse `keep`, `empty`, `ready:slot`, or an item name.
An omitted hand inherits the default requirement; explicit `keep` leaves that
hand unmanaged. No equipment is inferred or substituted.

Add `hunting_loadout_rules`, an ordered list. Each rule names a set and a target
name pattern, a creature type, or both. First match wins; both selectors on one
rule must match. Target patterns use the existing Targets matching semantics.
Types are living, undead, and noncorporeal, using existing parsed creature
facts. Unknown creature classification must not silently count as living.
No match or no eligible target selects the default.

Validate missing sets, malformed structures, unsupported fields, selector
values, and invalid patterns before game actions. Rules choose equipment for
the target selected by Engage/Assist; they do not choose combat targets.

## Equipment ownership

1. Rest departure preparation uses the default set, never an opportunistic
   room creature's set. Travel owns its existing temporary equipment.
2. Before a new target's routine acts, establish that target's selected set.
   Recheck the target when state changes during equipment preparation.
3. An active routine may intentionally wield/store other equipment. Do not
   reapply its starting set between dependent routine steps.
4. Priority and Assist retargeting end the previous routine's ownership even
   when its old creature remains alive. The next target needs its own handoff.
5. Thrown-weapon recovery is equipment work even after a target dies. Reuse
   existing recovery actions and core return events; do not fill a returning
   weapon's hand or declare it lost solely because the target disappeared.
6. Recovery must be bounded, respect interruption, and keep survival/return
   behavior intact. Do not chase items into another room autonomously.
7. Unresolved required equipment follows the existing loadout failure/return
   path, with explicit diagnostics. No silent fallback to the wrong set.

## Implementation split

- Configuration: pure Selection module, profile loading, validation, tests.
- Handoff: Loadout behavior and existing Engage/Assist target seam; tests with
  the real engine arbiter rather than only mocked ownership predicates.
- Return: existing Hurl/Dhurl/RecoverHurl integration, opt-in for managed
  loadouts, bounded outcomes and delayed-return tests.
- Integration: source review, complete specs, RuboCop, single-file build,
  documentation coverage, updated profile/routine/architecture guides.

No new inventory scanner, creature classifier, UI toolkit, disarm message
parser, or general-purpose resource lease framework is planned.

Managed ordinary/directed throws reuse RecoverHurl synchronously with original
hand identity checks, the existing six-second flight window, and a ten-second
total recovery budget. Ambiguous or replacement identities fail explicitly.
Generated projectiles and custom retrieval commands are not claimed supported.

## Verification

The reproduced priority-target bug must first fail and then pass. Cover
default-only profiles; unmanaged profiles; named sets with unmanaged default;
specific-target versus category ordering; overlapping undead/noncorporeal
rules; unknown classification; invalid configuration; same-target routine
swaps; priority and Assist switches; target disappearance during preparation;
late/missing weapon return; interrupted recovery; and rest/travel/loot ownership.

Existing baseline, controller, group, and stranded-return tests remain green.
Live acceptance, if later authorized, begins and ends in a designated safe
room and uses a bounded low-risk encounter. Offline tests are not proof of
compatibility with every scripted returning weapon.

## Verification closeout

- Outcome: named sets, ordered creature rules, action-time target handoffs,
  and bounded managed Hurl/Dhurl recovery implemented; GUI deferred.
- Evidence: the original priority-switch reproduction went from failing to
  passing. Full suite: 589 examples, zero failures; RuboCop: 66 files clean;
  single-file build and Ruby syntax pass; YARD: 100% documented.
- Independent review: Spec reported no findings. Standards found one guide
  inconsistency about explicit null structured settings; documentation and
  cleaner comments were corrected without changing validation behavior.
- Remaining work: player-authorized live acceptance and the separately
  diagnosed Lich Stash permanent-displacement fix upstream. No runtime
  deployment or in-game commands were performed for this extension.
- Scope limits: generated projectiles, replacement-ID returns and custom
  retrieval commands are not claimed supported. No private character
  configuration was changed. Sophia was unavailable; source/tests are the
  durable handoff rather than a separate knowledge submission.
