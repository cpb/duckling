# Research & Planning — Issue #1: Ship duckling gem (time extraction via Magnus + wafer-inc-duckling)

**What this PR answers:** How to ship a Ruby gem that extracts time/date entities from
text using the wafer-inc-duckling Rust crate wrapped via Magnus — no Haskell runtime, no
HTTP call — and publish it as `duckling` 0.2.0.

## Reading Order

Start here, then follow the path for your role:

**Implementer** (writing code): Plans → 01 → 02 → 03 (in that order).

**Reviewer** (understanding design): Research Key Findings → Plans Key Decisions → Plans.

**Newcomer** (orienting to the space): Research → Plans.

## Table of Contents

### Research

- [research/README.md](./research/README.md) — Breadth-first summary and key findings across all research topics.
  - [research/wafer-inc-duckling-api/](./research/wafer-inc-duckling-api/README.md) — Complete public Rust API: parse functions, types, time semantics, locale system.
    - [public-functions.md](./research/wafer-inc-duckling-api/public-functions.md) — `parse()` and `parse_en()` signatures; crate type (rlib); no Magnus dependency.
    - [types.md](./research/wafer-inc-duckling-api/types.md) — All public types with Mermaid diagrams; Naive vs Instant distinction.
    - [locale-system.md](./research/wafer-inc-duckling-api/locale-system.md) — 49 Lang variants, 25 Region variants, Context, Options (with_latent defaults false).
  - [research/build-wiring/](./research/build-wiring/README.md) — Magnus + rb-sys native extension build plumbing.
    - [extension-crate.md](./research/build-wiring/extension-crate.md) — cdylib crate layout; wafer-inc-duckling path dep; crates.io blocker.
    - [extconf-rb.md](./research/build-wiring/extconf-rb.md) — Verified 3-line extconf.rb from rust_blank example.
    - [rakefile-setup.md](./research/build-wiring/rakefile-setup.md) — ExtensionTask and lib_dir.
    - [ci-configuration.md](./research/build-wiring/ci-configuration.md) — Rust toolchain action; source vs. binary gem tradeoff.
  - [research/type-mapping-strategy/](./research/type-mapping-strategy/README.md) — Rust→Ruby type conversion options.
    - [serialization-options.md](./research/type-mapping-strategy/serialization-options.md) — serde_magnus vs. manual Magnus vs. JSON; verified serde attributes; recommendation.
    - [ruby-hash-schema.md](./research/type-mapping-strategy/ruby-hash-schema.md) — Target Ruby hash shape; NaiveDateTime tension; Grain string mapping.
    - [magnus-type-conversions.md](./research/type-mapping-strategy/magnus-type-conversions.md) — IntoValue table; chrono feature; working Rust example for entity hash.
  - [research/test-coverage/](./research/test-coverage/README.md) — Test cases and minitest design.
    - [corpus-cases.md](./research/test-coverage/corpus-cases.md) — wafer-inc-duckling time corpus; 10 categories; Rust test helper patterns.
    - [ruby-test-design.md](./research/test-coverage/ruby-test-design.md) — REFERENCE_TIME, assertion helpers, 8 test classes.
    - [pyduckling-reference.md](./research/test-coverage/pyduckling-reference.md) — pyduckling test inventory; port vs. skip decisions.

### Plans

- [plans/README.md](./plans/README.md) — Breadth-first summary; dependency order; key decisions table.
  - [plans/01-native-extension-setup.md](./plans/01-native-extension-setup.md) — Wire ext/duckling cdylib crate, extconf.rb, Rakefile, CI.
  - [plans/02-ruby-api-design.md](./plans/02-ruby-api-design.md) — `Duckling.parse` API, manual Magnus mapping, NaiveDateTime handling.
  - [plans/03-test-suite-and-ci.md](./plans/03-test-suite-and-ci.md) — Failing tests first; six test classes; RubyGems 0.2.0 checklist.

## Critical Open Questions (requiring human decision)

1. **wafer-inc-duckling not on crates.io.** The Cargo path dependency works for local
   development but will not work when the gem is installed from RubyGems. Must choose:
   (a) publish wafer-inc-duckling to crates.io, (b) use a git dependency, or (c) vendor
   the Rust source. Blocks RubyGems publication of 0.2.0.
   → See [extension-crate.md](./research/build-wiring/extension-crate.md)

2. **NaiveDateTime timezone in Ruby output.** Wall-clock expressions like "tomorrow"
   produce `TimePoint::Naive` with no timezone. Option N1 (bare ISO8601) differs from
   pyduckling's timezone-aware output. This affects test parity assertions.
   → See [ruby-hash-schema.md](./research/type-mapping-strategy/ruby-hash-schema.md)

3. **`reference_time:` type in Ruby API.** Plan 02 proposes `i64` Unix timestamp.
   A Ruby `Time` object would be more ergonomic but requires more Magnus plumbing.
   → See [02-ruby-api-design.md](./plans/02-ruby-api-design.md) Open Questions
