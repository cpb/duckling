# Roadmap: Research → PR #2 Green

This document is the single-page answer to "what must happen, in order, for PR #2's hill
tests to go from failing to passing."

PR #2 branch: `issue-1/ship-duckling-gem-time-extraction-via-magnus-wafer`
PR #2 tests: `test/duckling_test.rb` (7 test classes, 1 already passing)

---

## Dependency graph

```
Plan 01 (compile wiring)
  └→ DucklingCiTest passes          (ext/duckling/Cargo.toml present)
  └→ Native extension loads          (rake compile succeeds)
       └→ Plan 02 Phase 1 (entity shape)
            └→ DucklingApiTest        (returns Array — already passing with [] stub)
            └→ DucklingEntityShapeTest (keys + value shape correct)
            └→ DucklingTimeExtractionTest (:time dim + valid grain)
       └→ Plan 02 Phase 2 (parity + interval)
            └→ DucklingParityTest     (full "Call me tomorrow" entity)
            └→ DucklingIntervalTest   ("from 3pm to 5pm" with from/to subkeys)
  └→ Plan 03 step 5 (version bump)
       └→ DucklingVersionTest         (VERSION == "0.2.0")
```

---

## Step 1 — Plan 01: Wire the native extension

**Goal:** `DucklingCiTest` passes; `rake compile` succeeds without error.

| File | Action |
|------|--------|
| `ext/duckling/Cargo.toml` | Create — cdylib crate, `duckling = "0.4"`, `magnus = "0.9"`, `rb-sys` |
| `ext/duckling/src/lib.rs` | Create — empty `#[magnus::init]` stub |
| `ext/duckling/extconf.rb` | Fill — 3-line `create_rust_makefile("duckling/duckling")` |
| `Rakefile` | Add `Rake::ExtensionTask` with `lib_dir = "lib/duckling"` |
| `lib/duckling.rb` | Add `require_relative "duckling/duckling"` |
| `.github/workflows/main.yml` | Add `dtolnay/rust-toolchain@stable` step |

See [01-native-extension-setup.md](./01-native-extension-setup.md) for the exact content
of each file.

After this step:
- `DucklingCiTest#test_native_extension_infrastructure` → **passes**
- `bundle exec rake compile` → succeeds
- All other tests still fail (bridge registers no methods yet)

---

## Step 2 — Plan 02 Phase 1: Implement `Duckling.parse` — entity shape

**Goal:** `DucklingEntityShapeTest` and `DucklingTimeExtractionTest` pass.

Register `Duckling.parse` in the `#[magnus::init]` function. The parse function must:

1. Accept `text` (positional String) and `locale:`, `dims:`, `reference_time:`, `with_latent:` keywords.
2. Call `duckling::parse(...)` with the resolved locale, dims, context, and options.
3. Return an `RArray` of entity hashes with **symbol keys**:
   - `:body` (String), `:start` (Integer), `:end` (Integer)
   - `:dim` (Symbol) — from `entity.value.dim_kind().to_string()` → `ruby.to_symbol(&dim_str)`
   - `:latent` (bool) — only when `entity.latent` is `Some`
   - `:value` (Hash) — see entity shape below

Entity `:value` hash for `TimeValue::Single`:
```ruby
{ type: :value, value: "2013-02-13T00:00:00", grain: :day, values: [...] }
```

Entity `:value` hash for `TimeValue::Interval`:
```ruby
{ type: :interval, from: { type: :value, grain: :hour, value: "..." },
                   to:   { type: :value, grain: :hour, value: "..." } }
```

Key implementation note: all `h.aset(...)` calls use `ruby.to_symbol("key")` as the key
argument, not plain string literals. Grain and type values are also symbols:
`ruby.to_symbol(grain.as_str())`, `ruby.to_symbol("value")`, `ruby.to_symbol("interval")`.

After this step:
- `DucklingEntityShapeTest#test_parse_result_shape` → **passes**
- `DucklingTimeExtractionTest#test_parses_time_dimension` → **passes**

---

## Step 3 — Plan 02 Phase 2: Parity and interval shape

**Goal:** `DucklingParityTest` and `DucklingIntervalTest` pass.

No new code structure needed — these tests fail because the entity values are wrong, not
because of a missing method. Ensure:

For **parity** ("Call me tomorrow" → body `"tomorrow"`):
- The `entity.body` field is extracted correctly (it is `"tomorrow"` because duckling
  isolates the matched span, not the full input).
- `value[:grain]` is `:day` (Naive, `Grain::Day` → `as_str() == "day"` → `ruby.to_symbol("day")`).
- `value[:value]` starts with `"2013-02-13"` — verify the reference_time context produces
  the right date. With the corpus reference time (Unix seconds of 2013-02-12T06:30:00Z),
  "tomorrow" resolves to 2013-02-13.
- `value[:values]` is a non-empty Array — `TimeValue::Single.values` contains at least one
  `TimePoint` element.

For **interval** ("from 3pm to 5pm"):
- `entity[:value][:type]` → `:interval`
- `entity[:value][:from][:type]` → `:value`
- `entity[:value][:from][:grain]` → `:hour`
- `entity[:value][:to][:type]` → `:value`
- `entity[:value][:to][:grain]` → `:hour`

The interval code path is in `time_value_to_ruby` for `TimeValue::Interval`. Both `from`
and `to` must be present (they are `Option<TimePoint>` — for a closed interval like "from
3pm to 5pm" both are `Some`).

After this step:
- `DucklingParityTest#test_parity_with_wafer_inc_duckling` → **passes**
- `DucklingIntervalTest#test_parses_interval` → **passes**

---

## Step 4 — Plan 03 step 5: Bump VERSION

Change `lib/duckling/version.rb`:
```ruby
VERSION = "0.2.0"
```

After this step:
- `DucklingVersionTest#test_version_is_0_2_0` → **passes**

---

## Step 5 — Verify all 7 tests pass

```
bundle exec rake compile test standard
```

Expected:
```
7 runs, N assertions, 0 failures, 0 errors, 0 skips
```

---

## Pre-implementation checklist

Before writing any Rust code, confirm:

- [ ] `duckling = "0.4"` resolves from crates.io (run `cargo search duckling` or check
      https://crates.io/crates/duckling)
- [ ] Magnus 0.9 is available (`cargo search magnus`)
- [ ] `ruby.to_symbol("body")` is the correct Magnus API for creating interned Ruby Symbols
      (verified in [`src/symbol.rs`](https://github.com/matsadler/magnus/blob/4e46772050e47cd6cd988fa935263cc5c583e388/src/symbol.rs) — method is `Ruby::to_symbol`; there is no `Ruby::sym` and no `src/ruby.rs` in magnus)
- [ ] `DimensionKind::Time.to_string()` returns `"time"` (verified from types.md Display table)
- [ ] `Grain::Day.as_str()` returns `"day"` (verified from types.md Grain table)

---

## Known limitations accepted for 0.2.0

| Limitation | Impact | Plan |
|------------|--------|------|
| `reference_time` reconstructed at UTC+0 | "now" tests with exact ISO8601 offset will fail | Extended corpus tests use prefix matching; hill tests do not test Instant ISO exactly |
| NaiveDateTime has no offset in output | Diverges from pyduckling | Documented in README; `value[:value]` prefix assertions avoid the issue |
| `with_latent:` not tested in hill | latent option is wired but untested by PR #2 | Post-PR-#2 corpus tests cover it |
| Only `DimensionValue::Time` handled | Other dims raise `ArgumentError` | Default `dims: ["time"]` means callers never hit this |

---

## Post-PR-#2 follow-on work

These do not need to be resolved to make PR #2 green but are natural next steps:

1. **Extended test corpus** — add `test/duckling_time_test.rb` with the full
   `TestDucklingParseTimeBasic`, `TestDucklingParseTimeWeekdays`, etc. classes from
   [ruby-test-design.md](../research/test-coverage/ruby-test-design.md).

2. **`reference_time:` timezone preservation** — accept a Ruby `Time` object and extract
   both `.to_i` (Unix seconds) and `.utc_offset` (seconds east of UTC) via Magnus to build
   a correct `DateTime<FixedOffset>`.

3. **Additional dimensions** — the 14 `DimensionKind` variants. Each needs a
   `DimensionValue::Foo { ... }` arm in `entity_to_ruby`. The serde shape analysis in
   [serialization-options.md](../research/type-mapping-strategy/serialization-options.md)
   shows that manual mapping is needed for all variants (not just Time).

4. **Upstream serde attributes** — opening a PR to wafer-inc/duckling to add
   `#[serde(tag = "type", rename_all = "lowercase")]` to `DimensionValue`, `TimeValue`,
   `TimePoint`, and `#[serde(rename_all = "lowercase")]` to `Grain` would unlock Option A
   (serde_magnus) and reduce the manual mapping code substantially.
