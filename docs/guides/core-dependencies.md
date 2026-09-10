# Core dependencies

The engine leans on Lich for everything Lich can do: combat parsing,
the PSM readers, the spell and effect state, item handling, routing,
the group, the societies. Some of what it needs is in open lich-5 pull
requests. This page lists them, what each provides, and how the test
package fills the gap until they merge.

## The check at startup

`eohunter.lic` checks for a few constants before it loads the engine
(`Lich::Gemstone::Fog`, `Combat::Messages`, `Stance`, `Mana`) and exits
with a message naming the test package when one is missing. Those are
the sentinels; the full list below is what the engine actually uses.

## Open lich-5 pull requests

| PR | Provides | Used by |
|---|---|---|
| #1578 | `Lich::Gemstone::Stance`, a shared stance setter | every stance change |
| #1579 | `Lich::Stash.wield`, `Stash.hands`, `Stash.open_container` | wield and store, the refused-fire stow |
| #1580 | `Lich::Gemstone::Mana.pulse` | Cleanse, the fog return |
| #1581 | `Lich::Gemstone::Bank`, Currency refresh, WEALTH lines | the bounty objective |
| #1582 | the Injured cache on the class, keyed on an injury fingerprint | the ability gates |
| #1583 | PSM `command` and `results_regex` readers | every maneuver |
| #1584 | `Lich::Gemstone::Fog`, the ways home | Rest's fog return |
| #1585 | a spell's start message refreshes a refreshable timer | Maintain's timing |
| #1586 | `Combat::Messages`, non-combat message families as observer events | the watch |
| #1587 | bounded `fput`: `max_resends`, `interrupt`, `resend_transient`, failure symbols | the send ladder |
| #1588 | `Group.broken?` waits on `Lich::Claim::Lock` | the claim |
| #1589 | society `command` readers | Wrack, the symbols and sigils |
| #1590 | `Spell.results_regex` | cast confirmation |
| #1591 | `Group.join` | the follower's join |
| #1575 | opt-in bounded script execution guards (ATARI) | the LAB controller only |
| #1576 | combat observation provenance (ATARI) | the LAB controller only |
| #1577 | static-only map route selection (ATARI) | the LAB controller only |

The last three are not needed for ordinary hunting.

## Already on upstream main

Everything else the engine reads is in Lich 5.20.1: `Lich::Claim`,
`Lich::Gemstone::Status`, `Injured`, `Experience`, `GameObj.targets`
and `hidden_targets`, `Overwatch`, `Creature` and `CreatureInstance`,
`Combat::Observers` and `Tracker`, `Group`, `Bounty`, `StowList`,
`CMan` and the other PSM modules, `Armaments::WeaponStats`, `Wounds`,
`Societies`, `Map`, the `check*` globals. The core consumption audit
(`docs/core-consumption-audit.md`) walks each engine file and names
what it reads.

## The test package

Until the PRs merge, the eohunter test package at
https://github.com/Nisugi/lich-5/releases is Lich main with all of the
above merged on a branch (`test/eohunter-package-<n>` on the Nisugi
fork), plus the script and an effect list. Each release's README says
which PRs it carries and which Lich version it was built from. Unzip
over the Lich root; restore the backup to revert.

When a PR merges upstream, the package drops it and the next Lich
release carries it. When all of them have merged, the package goes
away and the script runs on stock Lich.
