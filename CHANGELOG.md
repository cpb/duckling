# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Breaking:** `reference_time:` now requires a Ruby `Time` object (or
  `nil`), not a Unix-seconds Integer. This lets the caller's `utc_offset` be
  preserved into offset-aware `Instant` results (e.g. `"in one hour"`),
  which previously always came back as UTC+0 regardless of the intended
  anchor. Migrate a raw Integer by wrapping it in `Time.at(seconds)`.

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
