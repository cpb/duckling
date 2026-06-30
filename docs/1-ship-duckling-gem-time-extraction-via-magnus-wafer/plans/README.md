# Plans — Issue #1: Ship duckling gem (time extraction via Magnus + wafer-inc-duckling)

Three sequenced implementation plans. Each plan is ≤ 200 lines and cross-links to
the research docs that ground its decisions. Execute in order: 01 → 02 → 03.

## Table of Contents

- [01-native-extension-setup.md](./01-native-extension-setup.md) — Wire the cdylib extension crate at `ext/duckling/`, fill `extconf.rb`, add `Rake::ExtensionTask`, and add the Rust stable toolchain to CI.
- [02-ruby-api-design.md](./02-ruby-api-design.md) — Implement `Duckling.parse(text, locale:, dims:, reference_time:)` in Rust via manual Magnus mapping; bump VERSION to 0.2.0.
- [03-test-suite-and-ci.md](./03-test-suite-and-ci.md) — Write failing minitest tests first (test-first label), with fixed reference time 2013-02-12 04:30 UTC-2 and six test classes covering basic/weekday/date/relative/latent parsing.

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
| Manual Magnus mapping, not serde_magnus | 02 | Verified serde attributes produce wrong shape |
| NaiveDateTime → bare ISO8601 (no offset) | 02 | Semantically honest; avoids threading Context into serialization |
| `reference_time:` as Unix i64 | 02 | Enables deterministic test assertions |
| No `build.rs` in extension crate | 01 | Magnus propagates rb_sys link metadata transitively |
| `duckling = "0.4"` crates.io dep | 01 | Published as `duckling` on crates.io — no path dep needed |
