# Plan 03: Test Suite and CI

## Decision

**The hill tests already exist on branch `issue-1/ship-duckling-gem-time-extraction-via-magnus-wafer`
(PR #2) in `test/duckling_test.rb`.** This plan documents their design and what remains
to be done. Do not create new test files — extend/verify the existing hill file.

Key decisions locked by the hill tests:
1. **Symbol keys and values throughout**: `:body`, `:dim`, `:value`, `:type`, `:grain`, etc.
   All entity hash keys and dim/type/grain values are Ruby Symbols.
2. **Test file**: `test/duckling_test.rb` (not `test/test_duckling.rb`) — already exists.
3. **Fixed reference time**: `REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")` — matches the corpus.
4. **NaiveDateTime format**: Bare ISO8601 without offset (Option N1). Hill test asserts
   `assert_match(/\A\d{4}-\d{2}-\d{2}/, entity[:value][:value])` — prefix only.
5. **Latent default**: `Options::default()` has `with_latent: false` — latent excluded.
   ([wafer-inc-duckling-api/public-functions.md](../research/wafer-inc-duckling-api/public-functions.md))
6. **CI**: Add `dtolnay/rust-toolchain@stable` before the rake step.
   ([ci-configuration.md](../research/build-wiring/ci-configuration.md))

## Rationale

The corpus reference time (2013-02-12 04:30:00 UTC-2) is the same value used in the
1300+ line `src/corpus/time_en.rs` Rust test file. Reusing it means test expected values
can be verified directly against the Rust corpus without re-computing them.
([corpus-cases.md](../research/test-coverage/corpus-cases.md))

The `assert false` placeholder in `test_it_does_something_useful` already causes CI
failure — replacing it with real failing tests is a safe substitution that preserves
the "red bar before green bar" intent.

See [ruby-test-design.md](../research/test-coverage/ruby-test-design.md) for the full
test class design and [pyduckling-reference.md](../research/test-coverage/pyduckling-reference.md)
for the decision on which pyduckling tests to port vs. skip.

## Steps

### 1. `test/test_helper.rb` — Add reference constant (if not already there)

The hill tests use `REFERENCE_TIME` directly. If it's not in test_helper.rb, add it there:

```ruby
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")
```

All time-parsing tests pass `reference_time: REFERENCE_TIME.to_i`. The `.to_i` converts
the Ruby Time to Unix seconds. Note: the UTC offset is lost (see plan 02 timezone note).

### 2. `test/duckling_test.rb` — The hill test file (already exists)

Do NOT create new test files. The hill tests are at `test/duckling_test.rb`. After
implementation, these tests go from failing to passing. The hill test classes and their
assertions:

| Class | Key assertions (all symbol keys) |
|-------|----------------------------------|
| `DucklingApiTest` | `Duckling.parse(...)` returns Array — already passing |
| `DucklingEntityShapeTest` | `:body`, `:start`, `:end`, `:dim`, `:value` present; `:value` has `:type`, `:value`, `:grain` |
| `DucklingTimeExtractionTest` | `r[:dim] == :time`, grain is in `VALID_GRAINS` |
| `DucklingParityTest` | body `"tomorrow"`, `dim: :time`, `value[:type]: :value`, `value[:grain]: :day`, ISO prefix, non-empty `:values` |
| `DucklingIntervalTest` | `value[:type]: :interval`, `:from`/`:to` each with `type: :value, grain: :hour` |
| `DucklingVersionTest` | `Duckling::VERSION == "0.2.0"` |
| `DucklingCiTest` | `ext/duckling/Cargo.toml` exists with `[lib]` + `crate-type = ["cdylib"]` |

For extended corpus coverage beyond the hill (post-PR-#2), add a separate
`test/duckling_time_test.rb` using the classes in [ruby-test-design.md](../research/test-coverage/ruby-test-design.md),
updated to use symbol keys.

### 3. Extended test helper (post-PR-#2)

When adding corpus-coverage tests beyond the hill in `test/duckling_time_test.rb`, use
symbol keys:

```ruby
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")

module DucklingTimeAssertions
  def parse_time(text, with_latent: false)
    Duckling.parse(text, locale: "en", dims: ["time"],
                   reference_time: REFERENCE_TIME.to_i, with_latent: with_latent)
  end

  def assert_time_naive(text, expected_date_prefix, expected_grain, msg = nil)
    result = parse_time(text)
    refute_empty result, "Expected parse result for #{text.inspect}"
    v = result.first[:value]
    assert_equal :value, v[:type], msg
    assert_equal expected_grain.to_sym, v[:grain], msg
    assert v[:value].start_with?(expected_date_prefix),
      "#{v[:value].inspect} should start with #{expected_date_prefix.inspect}"
  end
end
```

### 4. `.github/workflows/main.yml` — Add Rust toolchain step

Insert after the `ruby/setup-ruby` step and before `bundle exec rake`:

```yaml
- name: Set up Rust
  uses: dtolnay/rust-toolchain@stable
```

After plan 01's Rakefile changes, `bundle exec rake` runs `compile` then `test`
then `standard` — no separate compile step needed in CI.

### 5. VERSION bump — `lib/duckling/version.rb`

Change `VERSION = "0.1.0"` to `VERSION = "0.2.0"` (covered in plan 02 — noted
here for test-suite ordering: bump VERSION after tests are green).

### 6. RubyGems 0.2.0 publication (manual, post-CI green)

- `bundle exec rake build` → `pkg/duckling-0.2.0.gem`
- `gem push pkg/duckling-0.2.0.gem` (requires RubyGems credentials)
- Source gem: users must have Rust stable toolchain installed. No pre-compiled
  binaries for 0.2.0. Documented in README.

## Open Questions

- **"now" expected value**: `TimePoint::Instant` for `"now"` should equal the
  reference time `"2013-02-12T04:30:00-02:00"`. Confirm this is what
  wafer-inc-duckling actually returns (the corpus `check_time_instant` helper
  confirms this but verify the offset representation in Rust → Ruby round-trip).

- **"in 2 hours" grain**: The Rust corpus expects `Grain::Minute` for "in 2 hours"
  (not `Hour`). Verify: `"in 2 hours"` resolves to `06:30:00` at minute grain,
  because wafer-inc-duckling uses Minute for hour-offset calculations. The test
  above expects `"hour"` — check corpus-cases.md and fix before implementation.

- **Standard linter**: New test methods use string interpolation inside assertions.
  Run `bundle exec rake standard` to catch any style violations in test files.

## Verification

**Phase 1 — before native extension** (hill tests fail with expected messages):
```
bundle exec rake test
# DucklingApiTest                  1 pass  ([] stub is an Array)
# DucklingEntityShapeTest          1 fail  ("Expected at least one result")
# DucklingTimeExtractionTest       1 fail  ("Expected a :time dimension result")
# DucklingParityTest               1 fail  ("expected at least one entity")
# DucklingIntervalTest             1 fail  ("Expected false to be truthy")
# DucklingVersionTest              1 fail  (0.1.0 ≠ 0.2.0)
# DucklingCiTest                   1 fail  (ext/duckling/Cargo.toml missing)
```

**Phase 2 — after plan 01 (compile wiring)** (CI test should pass):
```
bundle exec rake test
# DucklingCiTest: 1 pass
```

**Phase 3 — after plan 02 (bridge implementation)**:
```
bundle exec rake test
# All 7 tests pass
bundle exec rake standard
# No offenses
```

**Phase 3 — manual smoke test** (matches plan 02 verification examples):
```ruby
require "duckling"
ref = REFERENCE_TIME.to_i
Duckling.parse("tomorrow", locale: "en", reference_time: ref)
# => [{"body"=>"tomorrow", "start"=>0, "end"=>8,
#      "value"=>{"type"=>"value", "value"=>"2013-02-13T00:00:00", "grain"=>"day",
#                "values"=>[...]}}]
```
