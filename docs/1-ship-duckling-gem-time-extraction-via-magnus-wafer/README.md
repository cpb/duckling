# Research & Planning — Issue #1: Ship duckling gem (time extraction via Magnus + wafer-inc-duckling)

**What this PR answers:** How to ship a Ruby gem that extracts time/date entities from
text using the [duckling](https://github.com/wafer-inc/duckling) Rust crate wrapped via Magnus — no Haskell runtime, no
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
    - [extension-crate.md](./research/build-wiring/extension-crate.md) — cdylib crate layout; [duckling](https://github.com/wafer-inc/duckling) path dep; crates.io blocker.
    - [extconf-rb.md](./research/build-wiring/extconf-rb.md) — Verified 3-line extconf.rb from rust_blank example.
    - [rakefile-setup.md](./research/build-wiring/rakefile-setup.md) — ExtensionTask and lib_dir.
    - [ci-configuration.md](./research/build-wiring/ci-configuration.md) — Rust toolchain action; source vs. binary gem tradeoff.
  - [research/type-mapping-strategy/](./research/type-mapping-strategy/README.md) — Rust→Ruby type conversion options.
    - [serialization-options.md](./research/type-mapping-strategy/serialization-options.md) — serde_magnus vs. manual Magnus vs. JSON; verified serde attributes; recommendation.
    - [ruby-hash-schema.md](./research/type-mapping-strategy/ruby-hash-schema.md) — Target Ruby hash shape; NaiveDateTime tension; Grain string mapping.
    - [magnus-type-conversions.md](./research/type-mapping-strategy/magnus-type-conversions.md) — IntoValue table; chrono feature; working Rust example for entity hash.
  - [research/test-coverage/](./research/test-coverage/README.md) — Test cases and minitest design.
    - [corpus-cases.md](./research/test-coverage/corpus-cases.md) — [duckling](https://github.com/wafer-inc/duckling) time corpus; 10 categories; Rust test helper patterns.
    - [ruby-test-design.md](./research/test-coverage/ruby-test-design.md) — REFERENCE_TIME, assertion helpers, 8 test classes.
    - [pyduckling-reference.md](./research/test-coverage/pyduckling-reference.md) — pyduckling test inventory; port vs. skip decisions.
  - [research/ffi-risks.md](./research/ffi-risks.md) — Tested evaluation of FFI binding risks (GVL blocking, panic safety, GC pressure, date rot, day-of-week validation gap).

### Plans

- [plans/README.md](./plans/README.md) — Breadth-first summary; dependency order; key decisions table.
  - [plans/00-pr2-roadmap.md](./plans/00-pr2-roadmap.md) — **Start here for implementation**: step-by-step path from research → PR #2 green; dependency graph; pre-implementation checklist.
  - [plans/01-native-extension-setup.md](./plans/01-native-extension-setup.md) — Wire ext/duckling cdylib crate, extconf.rb, Rakefile, CI.
  - [plans/02-ruby-api-design.md](./plans/02-ruby-api-design.md) — `Duckling.parse` API, manual Magnus mapping, symbol keys, NaiveDateTime handling.
  - [plans/03-test-suite-and-ci.md](./plans/03-test-suite-and-ci.md) — Hill tests already written in PR #2; extended corpus test design.

## Settled Decisions (were open; now closed)

- **[duckling](https://github.com/wafer-inc/duckling) on crates.io** — Published as `duckling = "0.4"`. Use crates.io
  dep in Cargo.toml. No publish blocker. (Resolved in commit b17070e.)
- **Symbol vs. String keys** — All entity hash keys and dim/type/grain values are Ruby
  Symbols (`:body`, `:dim`, `:value`, `:type`, `:grain`, `:day`, etc.). Settled by the
  hill tests in PR #2. All plan examples have been updated to reflect this.
  → See [ruby-hash-schema.md](./research/type-mapping-strategy/ruby-hash-schema.md)
- **NaiveDateTime format** — Option N1 (bare ISO8601, no offset). The hill test asserts
  a date prefix only, so this is acceptable for 0.2.0.
  → See [ruby-hash-schema.md](./research/type-mapping-strategy/ruby-hash-schema.md)

## Open Questions (still requiring decision or confirmation)

1. **`reference_time:` timezone loss.** Passing `reference_time` as a Unix `i64` loses
   the UTC offset. `DateTime::from_timestamp(secs, 0).fixed_offset()` reconstructs at
   UTC+0. The hill tests don't expose this (none test Instant values with exact ISO8601),
   but extended corpus tests (`"now"`) will fail unless the offset is preserved.
   Options: (a) accept i64 and document the UTC-0 reconstruction for 0.2.0; (b) accept a
   Ruby `Time` and extract both `.to_i` and `.utc_offset` via Magnus.
   → See [02-ruby-api-design.md](./plans/02-ruby-api-design.md) Open Questions

2. **`NoGrain` → `"nosec"` vs. `"no_grain"`.** `Grain::as_str()` returns `"no_grain"`;
   original Haskell/pyduckling uses `"nosec"`. Use `"no_grain"` for 0.2.0 and document.
   Verify whether any real Time entity in the corpus actually carries `NoGrain`.
   → See [ruby-hash-schema.md](./research/type-mapping-strategy/ruby-hash-schema.md)
