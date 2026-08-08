# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
  it has, and both remedies, so this is distinguishable from a typo:

  ```
  invalid reference_zone: "US/Eastern" (resolved against system zoneinfo at
  /usr/share/zoneinfo, which provides 497 identifiers; backward-compat names
  such as this one need either the tzinfo-data gem or the tzdata-legacy
  system package)
  ```

  A second, quieter difference comes with the same change: Debian and Ubuntu
  compile tzdata in *rearguard* format, which strips negative DST. On such a
  host `Europe/Dublin` is modelled as an ordinary positive-DST zone. Resolved
  offsets are the same either way — only tzinfo's `dst?` flag differs — so no
  `Duckling.parse` result changes because of it.

- `tzinfo-data` is no longer a runtime dependency. `tzinfo` already prefers
  that gem when it is installed and falls back to the host's zoneinfo files
  otherwise, so depending on it forced bundled tz data on every consumer to
  serve the ones who want it. This is the change that produces the identifier
  behavior above. Consumers who add `gem "tzinfo-data"` themselves get exactly
  the previous behavior with no code change, and can still pick up a
  tz-database revision by bumping that one gem. Dropping it makes the first
  zone lookup roughly 10× faster (13–28ms, once per process); steady-state
  resolution and RSS are unchanged.

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
