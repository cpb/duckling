# Plans — Issue #1: Ship duckling gem (time extraction via Magnus + wafer-inc-duckling)

Three sequenced implementation plans. Each plan is ≤ 200 lines and cross-links to
the research docs that ground its decisions. Execute in order: 01 → 02 → 03.

## Table of Contents

- [00-pr2-roadmap.md](./00-pr2-roadmap.md) — **Start here**: step-by-step roadmap mapping each PR #2 hill test to the plan step that makes it pass; dependency graph; pre-implementation checklist; known 0.2.0 limitations.
- [01-native-extension-setup.md](./01-native-extension-setup.md) — Wire the cdylib extension crate at `ext/duckling/`, fill `extconf.rb`, add `Rake::ExtensionTask`, and add the Rust stable toolchain to CI.
- [02-ruby-api-design.md](./02-ruby-api-design.md) — Implement `Duckling.parse(text, locale:, dims:, reference_time:, with_latent:)` in Rust via manual Magnus mapping with symbol keys; bump VERSION to 0.2.0.
- [03-test-suite-and-ci.md](./03-test-suite-and-ci.md) — Hill tests already written in `test/duckling_test.rb` (PR #2); this plan documents their structure and the extended corpus test design for post-PR-#2.

## Dependency Order

```
01 (compile) → 02 (API + types) → 03 (tests green + publish)
```

Plan 03 tests are written before Plan 02 is implemented — the native extension must
compile (Plan 01) for the tests to run at all, but they should fail until Plan 02
is complete.

## Key Decisions

| Decision | Plan | Rationale |
|----------|------|-----------|
| Symbol keys and Symbol values throughout | 02 | Hill tests in PR #2 assert `:body`, `:dim`, `:grain`, etc. |
| `:dim` key derived from `dim_kind().to_string()` | 02 | `Entity` has no `dim` field; must derive from `DimensionValue` variant |
| Manual Magnus mapping, not serde_magnus | 02 | Verified serde attributes produce wrong shape |
| NaiveDateTime → bare ISO8601 (no offset) | 02 | Semantically honest; hill test checks prefix only |
| `reference_time:` as Unix i64 (UTC+0 reconstruction) | 02 | Simple for 0.2.0; UTC offset loss is acceptable for hill tests |
| `with_latent: false` default, passable as keyword | 02 | Matches `Options::default()`; needed for latent test coverage |
| No `build.rs` in extension crate | 01 | Magnus propagates rb_sys link metadata transitively |
| `duckling = "0.4"` crates.io dep | 01 | Published as `duckling` on crates.io — no path dep needed |
| Tests in `test/duckling_test.rb` (hill already written) | 03 | PR #2 hill is authoritative; do not create new test files |
