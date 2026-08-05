# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-08-05

## What's Changed
* Add AGENTS.md: give agents an upfront repo map by @cpb in https://github.com/cpb/duckling/pull/8
* Enable branch protection on main by @cpb in https://github.com/cpb/duckling/pull/14
* Add Dependabot config for Cargo and Bundler by @cpb in https://github.com/cpb/duckling/pull/15
* Wire hk for centralized linting: StandardRB + rustfmt/clippy by @cpb in https://github.com/cpb/duckling/pull/18
* Pin GitHub Actions to commit SHAs and add Dependabot for Actions by @cpb in https://github.com/cpb/duckling/pull/16
* Update rake-compiler requirement from ~> 1.2.0 to ~> 1.3.1 by @dependabot[bot] in https://github.com/cpb/duckling/pull/19
* Add tag ruleset to prevent unauthorized release triggers by @cpb in https://github.com/cpb/duckling/pull/17
* Bump actions/checkout from 6.0.3 to 7.0.0 by @dependabot[bot] in https://github.com/cpb/duckling/pull/20
* Document Duckling.parse usage, return shape, and known limitations in README by @cpb in https://github.com/cpb/duckling/pull/22
* Remove hardcoded tool/crate versions from AGENTS.md by @cpb in https://github.com/cpb/duckling/pull/25
* Simplify rake release to tagging only, update docs to match by @cpb in https://github.com/cpb/duckling/pull/37
* Fill in bin/claude-code-web-setup with just-in-time dependency install by @cpb in https://github.com/cpb/duckling/pull/42
* Add :dev Rakefile task for faster edit-compile-test loop by @cpb in https://github.com/cpb/duckling/pull/39
* Add Brewfile + bin/setup Homebrew step for Rust toolchain by @cpb in https://github.com/cpb/duckling/pull/41
* Pin CI Rust toolchain to 1.94.1 (matches Claude Code Web sandbox) by @cpb in https://github.com/cpb/duckling/pull/40
* Explicit task test: :compile Rake dependency + fix bin/test file:line by @cpb in https://github.com/cpb/duckling/pull/49
* Skip bin/setup's .env.local seed when CI=true by @cpb in https://github.com/cpb/duckling/pull/51
* Scope hk to local dev only; drop it from remote/web sessions by @cpb in https://github.com/cpb/duckling/pull/52
* research(1): ship duckling gem — time extraction via Magnus + wafer-inc-duckling by @cpb in https://github.com/cpb/duckling/pull/3
* Add benchmark-ips suite with per-environment tracking and PR automation by @cpb in https://github.com/cpb/duckling/pull/59
* Publish precompiled binary gems for x86_64-darwin and x86_64-linux by @cpb in https://github.com/cpb/duckling/pull/60
* Expand CI test matrix: Ruby 3.4, latest Ruby, latest Rust by @cpb in https://github.com/cpb/duckling/pull/48
* Benchmark results (claude-code-web, 0.2.0) by @cpb in https://github.com/cpb/duckling/pull/62
* Extract benchmark recording into a standalone workflow by @cpb in https://github.com/cpb/duckling/pull/65
* Fix benchmark:record_pr's pipefail flag failing under dash by @cpb in https://github.com/cpb/duckling/pull/66
* docs: document hk stash/MERGE_HEAD gotcha and HK=0 workaround (#55) by @cpb in https://github.com/cpb/duckling/pull/67
* Benchmark results (github-actions, 0.2.0) by @github-actions[bot] in https://github.com/cpb/duckling/pull/68
* docs: roadmap update for issue #57 (research → wiki, plan → issue #64) by @cpb in https://github.com/cpb/duckling/pull/61
* Implement thread-per-call GVL release to unblock async reactor Fibers (#64) by @cpb in https://github.com/cpb/duckling/pull/50
* reference_time: accept a Ruby Time to preserve UTC offset by @cpb in https://github.com/cpb/duckling/pull/72
* Extend Ruby time-test corpus; return real Time objects for time values by @cpb in https://github.com/cpb/duckling/pull/54
* research(77): Spike — does rb_nogvl + RB_NOGVL_OFFLOAD_SAFE obviate the Thread wrapper? by @cpb in https://github.com/cpb/duckling/pull/81
* Split local benchmark buckets by Ruby minor version by @cpb in https://github.com/cpb/duckling/pull/79
* Tighten AGENTS.md for native-wrapper agent workflow by @cpb in https://github.com/cpb/duckling/pull/80
* Populate :value for all 13 non-Time dimensions via serde_magnus's generic symbolizer by @cpb in https://github.com/cpb/duckling/pull/93
* Gate informational CI jobs on the required baseline job passing by @cpb in https://github.com/cpb/duckling/pull/99
* Migrate DimensionValue::Time onto the unified serde_magnus tagged shape (#91) by @cpb in https://github.com/cpb/duckling/pull/97
* Give Duckling.parse an explicit Ruby signature by @cpb in https://github.com/cpb/duckling/pull/101
* Add DST-aware reference_zone: against #91's tagged Time shape by @cpb in https://github.com/cpb/duckling/pull/102
* Bump ruby/setup-ruby from 1.315.0 to 1.316.0 by @dependabot[bot] in https://github.com/cpb/duckling/pull/104
* Bump ruby/setup-ruby from 1.316.0 to 1.321.0 by @dependabot[bot] in https://github.com/cpb/duckling/pull/111
* Bump actions/checkout from 7.0.0 to 7.0.1 by @dependabot[bot] in https://github.com/cpb/duckling/pull/110
* Add two platforms, correct the precompiled gems, and test them before release by @cpb in https://github.com/cpb/duckling/pull/113

## New Contributors
* @dependabot[bot] made their first contribution in https://github.com/cpb/duckling/pull/19
* @github-actions[bot] made their first contribution in https://github.com/cpb/duckling/pull/68

**Full Changelog**: https://github.com/cpb/duckling/compare/v0.2.0...v0.3.0


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
