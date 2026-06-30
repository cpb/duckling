# Research — Issue #1: Ship duckling gem (time extraction via Magnus + wafer-inc-duckling)

Breadth-first summary of all research topics. Each subtopic is a self-contained terrain
map: observable facts, verified file paths, exact versions, and code references. No
prescriptive recommendations — those live in [`../plans/`](../plans/README.md).

## Table of Contents

- [wafer-inc-duckling-api/](./wafer-inc-duckling-api/README.md) — Complete public Rust API surface: parse functions, all types (Entity/DimensionValue/TimeValue/TimePoint/Grain), Naive vs Instant time semantics, and the 49-language locale system.
- [build-wiring/](./build-wiring/README.md) — How to wire the Magnus + rb-sys native extension: cdylib extension crate layout, extconf.rb pattern, Rakefile ExtensionTask, and CI Rust toolchain setup.
- [type-mapping-strategy/](./type-mapping-strategy/README.md) — Options for converting wafer-inc-duckling Rust types to Ruby (serde_magnus vs. manual Magnus mapping vs. JSON round-trip), verified serde attribute analysis, and the target Ruby hash schema.
- [test-coverage/](./test-coverage/README.md) — Time corpus cases from wafer-inc-duckling (1300+ lines), Ruby minitest test suite design with fixed reference time, and pyduckling parity scope for 0.2.0.
- [ffi-risks.md](./ffi-risks.md) — FFI binding risk analysis: GVL thread blocking (measured ~505µs/parse), panic safety (already mitigated by duckling), GC pressure, date rot (falsified through 2030), and Magnus 0.9 GVL API gaps.

## Key Findings

| Topic | Critical finding |
|-------|-----------------|
| wafer-inc-duckling-api | `Options::with_latent` defaults to `false` — latent entities excluded by default. `Grain::as_str()` returns `"no_grain"` (not `"nosec"`). `Entity` has no `dim` field — derive `:dim` from `entity.value.dim_kind().to_string()`. |
| build-wiring | No `build.rs` needed in the extension crate; Magnus propagates rb_sys link metadata transitively. `duckling` IS on crates.io as `duckling 0.4.0` — use `duckling = "0.4"`. |
| type-mapping-strategy | `serde_magnus` produces the wrong shape (externally-tagged enums, PascalCase grains). Manual Magnus mapping (Option B) is required. **All hash keys and grain/type/dim values must be Ruby Symbols** — use `ruby.sym("key")` in Rust. |
| test-coverage | Hill tests already written in PR #2 (`test/duckling_test.rb`); they assert symbol keys. Fixed reference time 2013-02-12 04:30:00 UTC-2 matches wafer-inc-duckling corpus. |
| ffi-risks | GVL hold measured at ~505µs for short inputs, ~3ms for long prose. Magnus 0.9 has no high-level GVL release API. Panic risk mitigated by duckling's own `catch_unwind`. Date rot hypothesis falsified (2030+ works). duckling does NOT validate day-of-week labels. |
