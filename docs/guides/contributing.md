# Contributing

How changes get in, and the conventions every pull request follows.

## The flow

- One pull request per fix or feature, against `main`. A PR that
  needs a lich-5 change says so in its description and names the lich
  PR; it waits until that lands in the test package, and the package
  README lists it.
- The engine consumes Lich; it does not fork it. A gap in Lich is a
  lich-5 PR to elanthia-online, from a branch on your fork. Never push
  to the elanthia-online remote directly.
- CI runs the specs, rubocop and the single-file build on every push.
  Green is the bar for review, not a substitute for it.
- Releases are tags `v<version>` matching `EO::Engine::VERSION`. The
  release workflow builds the single file, checks the tag matches, and
  attaches it. The version and the changelog block in `eohunter.lic`'s
  header move together.

## Conventions

**Code.** Ruby 3.4. Rubocop's Layout and Lint cops, ASCII-only source
(no em dashes or curly quotes anywhere, comments included), no Style
cops. Endless methods are fine. Keep a file to one concern; the parts
are named after theirs.

**Comments.** Every rule cites its source: the bigshot 5.16 or ecleanse
2.3.6 function and line it came from, as `(bigshot 7383)` in prose and
`@bigshot name 7383` in the docstring. Say why, not what, when the code
already says what.

**Docs.** YARD on every module, class, constant and public method; the
`docs` workflow publishes them. `rake doc:stats` must stay at 100%
documented. A change to the routine language, the profile keys, or a
behavior's rules updates the matching guide under `docs/guides/`.

**Specs.** Every action and behavior has one. A spec fakes the world
with structs and OpenStructs, stubs the send seam, and asserts on what
was sent and what was returned. No spec talks to Lich. The whole suite
runs in about a second; keep it that way.

**Commits.** A subject that says what changed and why in one line,
imperative mood, prefixed `feat:`, `fix:`, `refactor:`, `docs:`,
`build:` or `test:`. A body when the why needs more than a line.

## Reviewing

A review checks, in this order: does Lich already do this; does the
change read through World and send through an Action; is the rule
cited; is there a spec that would fail without the change; does the
docstring say what the method does. Then the code.

## Local setup

```
git clone https://github.com/Nisugi/hunter
cd hunter
bundle install
bundle exec rspec
bundle exec rubocop
bundle exec rake build
bundle exec rake doc
```

To test in the game, copy `scripts/eohunter.lic` and `scripts/eohunter/`
into the Lich from the test package, or build and drop the single file
into `scripts/`. There is no way to run a hunt outside the game; the
specs are the offline check.
