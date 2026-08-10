# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.1] - 2026-08-10

### Fixed

- The packaged gem no longer includes agent- and development-tooling files.
  0.3.0 and 0.4.0 shipped `.claude/settings.json`, `AGENTS.md`, and
  `CLAUDE.md`: the gemspec built its file list from `git ls-files` with a
  reject-list of paths to exclude, so every newly tracked dotfile or tool
  directory was packaged by default. The gemspec now allow-lists what ships
  (`lib/`, `ext/`, `docs/` other than `docs/benchmarks/`, and a named set of
  root files), so anything new stays out of the gem unless it is added
  deliberately. Regression coverage checks the gemspec's file list in the
  main suite and the built artifacts in `test/gem/packaged_gem_test.rb`.
  None of the previously shipped files contained secrets — they are
  development configuration and documentation, all public in the repository
  — so the already-published 0.3.0/0.4.0 gems are unaffected in behavior and
  have been left in place.

## [0.4.0] - 2026-08-10

### Changed

- **On a stock Debian/Ubuntu host, roughly a hundred IANA zone identifiers
  stop resolving.** `reference_zone: "US/Eastern"` — and every other
  backward-compatibility name, such as `"US/Pacific"`, `"Europe/Kiev"`, or
  `"Japan"` — now raises `ArgumentError` there. Those names live in the
  `tzdata-legacy` system package, which is not installed by default. Two ways
  to get them back, either of which restores the previous behavior exactly:

  ```ruby
  gem "tzinfo-data"   # in your Gemfile
  ```
  ```bash
  apt install tzdata-legacy   # on the host
  ```

  Canonical identifiers (`"America/New_York"`, `"Europe/Kyiv"`) are
  unaffected. A host with no zoneinfo files at all — a scratch or distroless
  container — needs the gem for `reference_zone:` to work at all.

  The error message names the tz database that answered, how many identifiers
  it has, and both remedies, so this is distinguishable from a typo. The
  datasource and the count describe whichever database answered on your host,
  so both differ from the example below:

  ```
  invalid reference_zone: "US/Eastern" (resolved against system zoneinfo at
  /usr/share/zoneinfo, which provides 497 identifiers; this database has no
  backward-compat names (US/Eastern and ~100 others), so if that is what this
  is, it needs either the tzinfo-data gem or the tzdata-legacy system package)
  ```

  The remedy is worded as a condition rather than a claim about the name you
  passed: whether a given identifier is one of the ~100 in IANA's `backward`
  file isn't knowable without shipping that list, and asserting it would tell
  every typo on such a host that `tzdata-legacy` will supply it.

  A second, quieter difference comes with the same change: some distributions
  compile tzdata in *rearguard* format, which strips negative DST, and on such
  a host `Europe/Dublin` is modelled as an ordinary positive-DST zone rather
  than a negative-DST one. Which distributions is not guessable — Ubuntu 24.04
  is rearguard, Debian trixie is vanguard — so if you depend on tzinfo's
  `dst?` flag, read it from the host rather than assuming. Resolved offsets
  are the same either way, so no `Duckling.parse` result changes because of
  it.

- `tzinfo-data` is no longer a runtime dependency. `tzinfo` already prefers
  that gem when it is installed and falls back to the host's zoneinfo files
  otherwise, so depending on it forced bundled tz data on every consumer to
  serve the ones who want it. This is the change that produces the identifier
  behavior above. Consumers who add `gem "tzinfo-data"` themselves get exactly
  the previous behavior with no code change, and can still pick up a
  tz-database revision by bumping that one gem. Dropping it means the bundled
  tz data is no longer loaded at boot, so the first zone lookup does less
  work; steady-state parsing is unaffected either way, since `reference_zone:`
  resolution goes through the same tzinfo call once a database is loaded.

### Added

- `Duckling::TZDataUnavailable`, raised when `reference_zone:` is given on a
  host with no tz database at all — no zoneinfo files and no `tzinfo-data`
  gem, as in a scratch or distroless container. Newly reachable because of the
  dependency change above; previously a database always existed. It names both
  fixes, where the underlying tzinfo error mentioned neither this gem nor
  `reference_zone:`. Deliberately not an `ArgumentError`: it reports the
  deployment's state, not a bad argument, so code rescuing `ArgumentError`
  around caller-supplied zone names does not swallow it. Every other keyword
  works without a tz database.

## [0.3.0] - 2026-08-04

### Changed

- **Breaking:** `reference_time:` now requires a Ruby `Time` object (or
  `nil`), not a Unix-seconds Integer. This lets the caller's `utc_offset` be
  preserved into offset-aware `Instant` results (e.g. `"in one hour"`),
  which previously always came back as UTC+0 regardless of the intended
  anchor. Accepted values: a `Time`, or anything responding to `to_time`
  (`ActiveSupport::TimeWithZone`, stdlib `DateTime`, etc.), which is coerced
  automatically. Migrate a raw Integer by wrapping it in `Time.at(seconds)`.
- **Breaking:** a time result's `:value` (and an interval's `:from`/`:to`) is
  now a real Ruby `Time`, not a formatted String. This applies to both
  `Naive` (wall-clock, e.g. `"tomorrow"`, `"5pm"`) and `Instant` (e.g. `"in
  one hour"`) results — `reference_time:`'s offset is now applied to
  `Naive` results too, not just `Instant` ones. Callers parsing the old
  ISO-ish string (with or without an offset suffix) should read `.value`
  directly as a `Time` instead.
- **Breaking:** `:time`'s `:value` now uses the same unified,
  externally-tagged shape as every other dimension: a single result is
  `{Time: {Single: {value: {Naive:|Instant: {value:, grain:}}, values: [...],
  holidayBeta: "..."}}}`, and an interval result is `{Time: {Interval: {from:
  {Naive:|Instant: {...}}, to: {...}, values: [...]}}}`. Previously `:time`
  kept its own bespoke flattened shape (`{type:, value:, grain:, values:}` /
  `{type:, from:, to:}`) even after every other dimension moved onto the
  tagged convention. `:value` is still always a real Ruby `Time`, never a
  String, and `grain` is still the lowercase-snake_case symbol convention
  (`:second`, `:no_grain`, ...) — only the wrapping shape changed. Migrate by
  reaching through the new tags, e.g.
  `entity[:value][:Time][:Single][:value][:Naive][:value]` in place of the
  old `entity[:value][:value]`. One behavior change bundled with the shape
  migration: an unbounded interval (e.g. `"after 3pm"`) now carries an
  explicit `to: nil` (or `from: nil`) key instead of omitting the key
  entirely — check `interval[:to].nil?` rather than `interval.key?(:to)`
  to detect an unbounded endpoint.

## [0.2.0] - 2026-07-01

## What's Changed
* Ship duckling gem: time extraction via Magnus + wafer-inc-duckling by @cpb in https://github.com/cpb/duckling/pull/2


**Full Changelog**: https://github.com/cpb/duckling/compare/v0.1.2...v0.2.0


## [0.1.2] - 2026-07-01

## What's Changed
* Retry release pipeline as 0.1.2 by @cpb in https://github.com/cpb/duckling/pull/7


**Full Changelog**: https://github.com/cpb/duckling/compare/v0.1.1...v0.1.2


## [0.1.1] - 2026-07-01

## What's Changed
* Automate gem release: tag-triggered publish to RubyGems by @cpb in https://github.com/cpb/duckling/pull/5

## New Contributors
* @cpb made their first contribution in https://github.com/cpb/duckling/pull/5

**Full Changelog**: https://github.com/cpb/duckling/compare/v0.1.0...v0.1.1
