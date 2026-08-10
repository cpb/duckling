# The tz-database axis

This document is the central reference for time zone (tz) data in this gem.
It replaces long inline comments. Keep inline comments short. Point here
instead.

## Why the tz database is an axis

`reference_zone:` resolves zones with the `tzinfo` gem. tzinfo uses the
`tzinfo-data` gem when that gem is installed. Without that gem, tzinfo uses
the zoneinfo files of the host. This gem does not depend on `tzinfo-data`.
Both configurations are valid production configurations.

The two databases do not give the same answers. They differ on three
independent axes:

- **Modelling.** Some distributions compile tzdata in rearguard format.
  Rearguard data strips negative DST. Example: `Europe/Dublin` is a
  negative-DST zone in vanguard data. It is an ordinary positive-DST zone in
  rearguard data. Ubuntu 24.04 and macOS ship rearguard data. Debian trixie,
  Alpine, and FreeBSD ship vanguard data.
- **Backward-compatibility links.** Debian and Ubuntu move the links to a
  separate `tzdata-legacy` package. That package is not installed by
  default. `US/Eastern` and approximately 100 other names then stop
  resolving. The identifier count drops from approximately 600 to
  approximately 500.
- **Vintage.** A pinned `tzinfo-data` gem or an unpatched host can predate a
  rule change. Example: `America/Nuuk` got new rules in tzdata 2023a. A
  2021–2022 vintage resolves the zone and answers with the old rules. Before
  2020a the name `America/Nuuk` does not exist at all.

A host can also have no tz database at all. Scratch and distroless
containers are examples. There `reference_zone:` raises
`Duckling::TZDataUnavailable`.

A suite run cannot observe which database it ran against. It passes
identically on both. Four mechanisms keep the coverage honest: environments,
probes, capability-gated tests, and environment contracts.

## Mechanism 1: Environments

Two environment variables select the database under test:

- `DUCKLING_TZINFO_DATA` (read in the Gemfile) controls the `tzinfo-data`
  gem in the bundle:
  - unset: the current release of the gem. This is the default environment.
  - `none`: no gem. tzinfo falls back to the zoneinfo files of the host.
  - an exact version, for example `1.2022.7`: a stale database.
- `DUCKLING_ZONEINFO_DIR` (read in `test/test_helper.rb`) points tzinfo at a
  specific compiled zoneinfo directory. It is set before `duckling` is
  required. Nothing then resolves a zone against the default source first.

Always set `BUNDLE_LOCKFILE` for any environment except the default.
Without it, `bundle install` overwrites the committed `Gemfile.lock`. The
per-environment lockfiles are gitignored (`/Gemfile.*.lock`). A dirty tree
also blocks `rake release` and `rake benchmark:record_pr`. Both are guarded
by `release:guard_clean`. The error looks unrelated.

An unrecognized `DUCKLING_TZINFO_DATA` value raises in the Gemfile. A typo
must fail there. It must not fail deep in the resolver as an unsatisfiable
constraint.

Seven environments run in CI:

| Environment | CI job | Database under test |
|---|---|---|
| default | `baseline` | current `tzinfo-data` gem |
| system-zoneinfo | `baseline` step | zoneinfo files of the runner |
| linkless-zoneinfo | `baseline` step | built by `bin/build-linkless-zoneinfo` |
| tzinfo-data 1.2022.7 | `timezones` matrix | pinned gem |
| stale system zoneinfo | `timezones` matrix | built by `bin/build-stale-zoneinfo` |
| Debian + tzdata-legacy | `tz-containers` matrix | system zoneinfo with the links |
| Alpine | `tz-containers` matrix | vanguard zoneinfo, musl source build |

Gating:

- Only `baseline` blocks a merge. It is the only required check. So the
  three environments a consumer is actually on run there as steps.
- `timezones` and `tz-containers` do not block a merge. They do block a
  release. `release.yml` waits on the full workflow (`needs: ci`). A red
  result there means "this vintage answers differently". It does not mean
  "the gem is broken for anyone today".

The linkless environment must be built. No runner is in that state.
`ubuntu-latest` resolves `US/Eastern` from its own tzdata. macOS does too.
Note: the runner is not a stock Ubuntu for tz data. A plain `ubuntu:24.04`
container of an earlier tzdata point release does not resolve the links.
The runner does. So no runner fact settles the links. The suite probes them.

One configuration deliberately has no environment: a host with no tz
database at all. A runner without tz data would break more than this gem.
Every probe answers `false` there. So the suite loads and runs. The
`DataSourceNotFound` arms assert this. `test/gem/installed_gem_test.rb`
skips its `reference_zone:` case there for the same reason.

## Mechanism 2: Behavioral probes

Neither datasource exposes a version. `RubyDataSource` keeps `version_info`
private. `ZoneinfoDataSource` exposes only `zoneinfo_dir`. So a probe asks
the database a question. It does not read a release string.

Probes are split by consumer:

- `Duckling::TZInfoCapabilities` (`lib/duckling/tzinfo_capabilities.rb`)
  ships in the gem. It holds only what the unknown-identifier error message
  needs.
- `TZCapabilities` (`test/support/tz_capabilities.rb`) holds the probes that
  only the suite calls. `lib/` reaches every consumer. `test/` reaches
  none. A probe with no production caller does not belong in `lib/`.

`backward_compat_links?` is needed on both sides. Production owns it. The
test module delegates to it.

Probe rules:

- A probe is a total boolean. It answers `false` on a host with no database.
  It must not raise. `TZInfo::DataSourceNotFound` is a sibling of
  `InvalidTimezoneIdentifier`. It is not a subclass. Rescue it explicitly.
- Nothing is memoized. `TZInfo::DataSource.set` can swap the database
  mid-process. The fixture-zone tests do this. A cached answer would
  describe a database that is no longer in use.
- `TZCapabilities.supports?` raises `ArgumentError` on an unknown capability
  name. A typo must be a hard error. It must not be a silent `false`.

The three probes:

- `models_negative_dst?` asks about `Europe/Dublin`. IANA models it as
  +01:00 standard all year, with a negative one-hour saving in winter. So
  tzinfo reports January as the `dst?` period. Rearguard data re-expresses
  the same offsets as ordinary positive DST.
- `backward_compat_links?` asks for `US/Eastern`. It is a link to
  `America/New_York` in IANA's `backward` file.
- `greenland_2023_rules?` asks whether `America/Nuuk` skips
  2026-03-28 23:30. Older vintages fail in two ways. Before 2020a the name
  does not exist. The 2021–2022 vintages know the name but answer with the
  old rules. The zone resolves and gives a different answer. That is the
  harder failure to attribute.

## Mechanism 3: Capability-gated tests

A test whose premise is a capability lives in
`test/capabilities/<capability>_test.rb`. The loader at the bottom of
`test/test_helper.rb` loads the file only where the probe passes. On a
database that cannot answer, the test is not in the run. It does not fail
for want of the capability. It does not pass vacuously.

The filename is the declaration. The loader calls `supports?` with the
filename. An unknown name raises at load time.

Rules:

- A test whose weak mode is a vacuous pass must assert its own premise.
  Example: `negative_dst_test.rb` asserts `models_negative_dst?` in the
  test body. The probe gates the load. The assertion catches the day the
  probe or the IANA data drifts. The test uses the same predicate as the
  loader. Two definitions could drift apart.
- A file run directly (`ruby -Itest test/capabilities/negative_dst_test.rb`)
  runs regardless of the probe. This is how you exercise one test against a
  database that lacks the capability.
- Do not use `expect_failure` for environment-dependent tests. It cannot
  tell an absent capability from a genuine regression. It would convert
  either into the same skip.

## Mechanism 4: Environment contracts

Each synthesized or pinned environment has a contract in
`test/environments/<name>_test.rb`. The CI step that creates the
environment invokes the contract directly:

```bash
bundle exec ruby -Ilib -Itest test/environments/<name>_test.rb
```

The suite never loads the contracts. A contract asserts its state
positively:

- `tzinfo_data_test.rb`: the datasource is the gem, and all three probes
  answer true. The default environment is the one place all three
  capabilities are guaranteed. So this contract is the tripwire for the
  loader. A probe that rotted to false would unload its capability file
  silently everywhere else. Here it turns red.
- `linkless_zoneinfo_test.rb`: `US/Eastern` raises, and the message names
  both remedies. It also asserts the identifier count stays in the range of
  a real links-less host. The build script's own check catches only
  under-stripping. Over-stripping is the likelier drift. A future tzdata or
  a different base image can add a top-level entry a real host keeps.
- `stale_vintage_test.rb`: `America/Nuuk` answers with the pre-2023a rules.
  The wrong answer is asserted on purpose. A stale database's dangerous
  failure is a wrong answer. A missing zone is easier to attribute. If the
  pin or the rollback
  stops taking effect, the capability-gated test simply starts loading and
  passing. The suite goes green against a different database than the
  environment exists for. This contract turns red instead.
- `system_zoneinfo_links_test.rb` and `alpine_vanguard_test.rb`: the
  defining probe answers true. An environment that lost its defining
  capability would silently run less. The contract is the loud half.

Without a contract, a broken setup presents as a smaller green suite. The
capability-gated files simply load less.

## The error messages

### Unknown identifier

`timezone_for` raises `ArgumentError` for an unknown identifier. The
message includes `unknown_identifier_diagnosis`. It names the database that
answered and how many identifiers it has. The count separates the two
databases legibly: approximately 600 against approximately 500.

Rules for the remedy clause:

- It is a condition the reader evaluates ("if that is what this is"). It is
  not a claim about the identifier. Only the database is checked here.
  Whether the name is one of the approximately 100 in IANA's `backward`
  file is not knowable without shipping that list. A claim would tell every
  typo on a links-less host that `tzdata-legacy` supplies it. A shipped
  list would be worse: a name it missed would get no remedy at all.
- The identifier the caller passed must not appear in the remedy clause.
  Naming it there turns the condition back into a claim.
- The clause appears only where the database has no links.
- The remedies assume the datasource is the host's default. A caller who
  pointed `TZInfo::DataSource` at their own directory must fix that
  directory instead. The message names the directory. That makes the case
  recognizable.

Rules for `datasource_description`:

- The zoneinfo case is detected by capability (`respond_to?(:zoneinfo_dir)`).
  A caller can install a custom subclass. The directory is the useful part
  of the answer.
- The gem case is detected by class. Whether `tzinfo-data` is loaded says
  nothing about whether it answered. A custom datasource in a bundle that
  also carries the gem must not be described as tzinfo-data.
- An unrecognized datasource is named by its own class. Do not describe it
  as another database.
- A host with no database gets its own string. This method builds failure
  messages. It must not raise. Raising would replace the explanation with a
  raw tzinfo error at the moment the explanation was wanted.

### No database at all

`timezone_for` raises `Duckling::TZDataUnavailable` when tzinfo raises
`DataSourceNotFound`. tzinfo raises it before any identifier lookup. The
zone name is beside the point. The message names the `reference_zone:`
keyword and both fixes: the `tzinfo-data` gem, or the system `tzdata`
package.

`TZDataUnavailable` is deliberately not an `ArgumentError`. It reports the
state of the deployment. A caller that validates user
input by rescuing `ArgumentError` must not swallow it. It is a named class
for the same reason as `ShapeError`: greppable, and not satisfiable by an
unrelated `RuntimeError`.

## Fixture zones

`test/fixtures/tz/*.zi` files are compiled by `zic` into a private zoneinfo
directory at test time. `TZFixtures::Datasource` swaps `TZInfo::DataSource`
in `setup` and restores it in `teardown`.

Why fixture zones:

- A fixture zone is identical on every host and every vintage. Real zones
  are not. Which real zones exist depends on the datasource. What they do
  depends on the vintage.
- The fixture directory exposes only its own three identifiers. Nothing
  about the host's database can leak into a test.
- The swap is process-global because `timezone_for` reaches the datasource
  through `TZInfo::Timezone.get` inside `Duckling.parse`. No injection
  point exists. This is also why Ruby doubles cannot replace the fixture
  zones. A double can only reach `local_time_in_zone` directly. That stops
  short of the outside-in path through `Duckling.parse`.
- The restore in `teardown` is mandatory. A leaked fixture
  datasource leaves every later test with three zones and nothing else.
- `TZInfo::DataSource.get` creates the default source when none is set. It
  raises when it cannot. So setup tolerates the absence. Teardown restores
  conditionally: `set(nil)` raises `ArgumentError`. On a failed setup that
  would replace the real error with a worse one.

The tests reach the fixtures through `Duckling.parse`. The coverage stays
outside-in. One exception: the half-hour gap test calls
`local_time_in_zone` directly. No English expression lands reliably inside
a 30-minute window.

The three fixture zones:

- `Fixture/NegativeDst`: shaped like `Europe/Dublin`. Negative DST. It
  distinguishes first-occurrence-by-position from a `dst?`-flag lookup.
  Picking by flag gives the second occurrence, an hour off as an instant.
  `ActiveSupport::TimeZone#local` picks by flag (`period_for_local`'s
  `dst=true` default).
- `Fixture/HalfHourGap`: shaped like `Australia/Lord_Howe`. A 30-minute
  gap. It distinguishes the transition's real width from a hardcoded
  one-hour shift. ActiveSupport's `@time += 1.hour` retry overshoots.
  Lord Howe is the only zone in current use with a sub-hour gap. The
  coverage rested on one zone's continued existence.
- `Fixture/LateGap`: shaped like `America/Nuuk`. A gap late in the local
  day in a negative-offset zone. The transition instant falls past the next
  UTC midnight. `gap_delta`'s scan window must center on the skipped wall
  clock read as UTC. A midnight-anchored window misses the transition.
  `gap_delta` then crashes with `NoMethodError` on a nil `find`.

`zic` needs no provisioning except on Alpine:

- Debian/Ubuntu: `zic` is in `libc-bin` (Priority: required, a dependency
  of libc6). It is not in `tzdata`. A slim image without
  `/usr/share/zoneinfo` still has it.
- macOS: `/usr/sbin/zic` is a stock utility.
- Alpine: `zic` is in `tzdata-utils`. The `tz-containers` job installs it.
- `zic` lives in `sbin`. That is off a non-root `PATH`. `TZFixtures` and
  `bin/build-stale-zoneinfo` search there explicitly.
- A missing `zic` is a hard error. These fixtures exist because this
  coverage kept degrading silently on hosts nobody watched. A skip would
  reintroduce exactly that.

## The build scripts

### `bin/build-linkless-zoneinfo <output-dir>`

Copies the host's zoneinfo directory and removes the top-level
backward-compatibility entries. `ZONEINFO_DIR` overrides the source
directory (default `/usr/share/zoneinfo`).

- The keep-list is transcribed from a real links-less host: a Debian-family
  container with `tzdata` and no `tzdata-legacy`, 497 identifiers. No name
  is added defensively. `Factory` and `posixrules` stay because Ubuntu
  24.04's tzdata 2025b still has them.
- The script hard-fails if `US/Eastern` survives the strip. That check
  catches under-stripping only. The environment contract's identifier-count
  range catches over-stripping.
- `cp -RL` dereferences the alias symlinks. Removing an entry cannot leave
  a dangling link. It cannot follow one back into the host's directory.
- The approximately 60 in-region aliases that `tzdata-legacy` also owns are
  not removed (`America/Godthab`, `Europe/Kiev`, `Asia/Calcutta`). Inside a
  region directory they are indistinguishable from aliases a stock host
  keeps (`Asia/Istanbul`, `Pacific/Samoa`). So the tree exposes more
  identifiers than a stock host. That costs nothing. The guarantee the
  environment needs is that `US/Eastern` is genuinely gone. It is the probe
  target and the name the CHANGELOG and the error message use.
- The copy keeps the host's modelling. Only the links absence gets an
  environment contract. Modelling follows the host. The capability-gated
  Dublin test loads or does not load.

### `bin/build-stale-zoneinfo <output-dir>`

Copies the host's zoneinfo directory and compiles
`test/fixtures/zoneinfo-overrides/*.zi` over it. The overrides roll named
zones back to earlier rules. `America/Nuuk` goes back to the pre-2023a
rules.

- The copy keeps the host's modelling and links state. The capability-gated
  tests absorb both.
- Rolling back only the zones under assertion says plainly which staleness
  is tested. Compiling a full old tzdata release would need a download.
- The override replaces the zone's entire history, including the pre-2023a
  rules. Harmless for the contract: it only looks at 2026. Every other zone
  in the copied directory stays as the host has it.
- This script needs `tzdata` installed. It copies `/usr/share/zoneinfo`. It
  fails with a clear message if the directory is missing.
- The override shadows a real identifier on purpose. The
  `test/fixtures/tz/*.zi` zones are `Fixture/`-prefixed so they cannot be
  mistaken for real ones. Here shadowing is the point. The environment must
  be a plausible stale host. A synthetic zone would give nothing to assert
  against.

## `expect_failure`

`expect_failure(reason)` in `test/test_helper.rb` is for known limitations
that fail on every host. The upstream grammar and ranking gaps are the
current cases. It runs the block for real:

- A failure reports as a skip that names the reason.
- A pass flunks. The limitation stopped reproducing. Drop the wrapper and
  keep the assertions.
- Only `Minitest::Assertion` is rescued. It inherits from `Exception`, not
  from `StandardError`. A wider rescue would launder any crash before the
  assertions into "known limitation". A genuine regression must surface as
  a crash.
- A `skip` inside the block is re-raised first. `Minitest::Skip` is a
  subclass of `Minitest::Assertion`. Otherwise the real explanation would
  be replaced by the reason.

Do not use it for anything environment-dependent. Use
`test/capabilities/` instead.

## Running an environment locally

Always pass `BUNDLE_LOCKFILE` to both the `bundle install` and the run.
The suite adapts itself to whatever database it gets. There is no
environment name to set. Run the matching contract afterward to prove you
got the state you meant to.

```bash
# no tzinfo-data: the host's zoneinfo files
export DUCKLING_TZINFO_DATA=none BUNDLE_LOCKFILE=Gemfile.system-zoneinfo.lock
bundle install && bundle exec rake test

# the same, with the backward-compat links stripped (US/Eastern stops resolving)
bin/build-linkless-zoneinfo /tmp/linkless-zoneinfo
DUCKLING_ZONEINFO_DIR=/tmp/linkless-zoneinfo bundle exec rake test
DUCKLING_ZONEINFO_DIR=/tmp/linkless-zoneinfo \
  bundle exec ruby -Ilib -Itest test/environments/linkless_zoneinfo_test.rb

# a pinned stale vintage
export DUCKLING_TZINFO_DATA=1.2022.7 BUNDLE_LOCKFILE=Gemfile.tzinfo-data-1.2022.7.lock
bundle install && bundle exec rake test
bundle exec ruby -Ilib -Itest test/environments/stale_vintage_test.rb

# both axes at once
bin/build-stale-zoneinfo /tmp/stale-zoneinfo
export DUCKLING_TZINFO_DATA=none BUNDLE_LOCKFILE=Gemfile.stale-system-zoneinfo.lock
bundle install && DUCKLING_ZONEINFO_DIR=/tmp/stale-zoneinfo bundle exec rake test
DUCKLING_ZONEINFO_DIR=/tmp/stale-zoneinfo \
  bundle exec ruby -Ilib -Itest test/environments/stale_vintage_test.rb
```

`DUCKLING_ZONEINFO_DIR` alone (pointing at `/usr/share/zoneinfo`, with
`tzinfo-data` still bundled) reaches the same datasource as the system leg
without re-resolving anything. It is the quick way to reproduce a
system-zoneinfo failure. It is not the same configuration. The gem is still
installed. So it does not exercise tzinfo's own fallback.

## CI notes

- `bundler-cache` is off in `timezones` and `tz-containers`. These
  environments resolve a different bundle than the committed lockfile. The
  cache is keyed on that lockfile.
- The system-zoneinfo step in `baseline` runs
  `bundle config unset --local deployment` (and `frozen`).
  `bundler-cache: true` writes `deployment: true` into `.bundle/config`.
  Deployment requires a committed lockfile. The environment lockfiles are
  gitignored by design. It must be unset in the local config.
  `BUNDLE_DEPLOYMENT` cannot override it. Bundler resolves local config first and environment
  variables second (`Bundler::Settings#configs`). An env var cannot
  override anything `bundle config --local` has written.
- The Alpine image is pinned by digest. The floating `ruby:3.4-alpine` tag
  silently rebases across Alpine releases. Alpine drops older versioned
  clang packages as it rolls. A rebase also moves the host's tz data under
  a leg that asserts against it. Bump by resolving the tag's current digest
  (`docker buildx imagetools inspect ruby:3.4-alpine`). Then re-verify the
  clang package names and the contract against the new release.
- Alpine splits clang's resource headers (`stdckdint.h`, which ruby-3.4's
  headers include) away from the library's default search path.
  `BINDGEN_EXTRA_CLANG_ARGS=-I<resource-dir>` points bindgen at them. Any
  musl consumer building the source gem needs the same. No precompiled gem
  targets musl (`cross_targets.rb`). So the source build is the path musl
  consumers actually take.
- The banner line at suite start (`tz datasource: ...; negative_dst=true
  ...`) records which database answered and which probes passed. Two images
  with the same name can disagree about the links. The banner is what
  reconciles a missing capability test with a CI log.
- The container jobs run the image's own Ruby. `ruby/setup-ruby` does not
  apply (it has no musl support). The toolchain comes from the image's
  package manager, git included. That is why the install step precedes
  checkout.
