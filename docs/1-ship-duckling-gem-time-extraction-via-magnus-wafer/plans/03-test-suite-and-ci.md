# Plan 03: Test Suite and CI

## Decision

Write failing minitest tests first (issue label: `test-first`), before implementing
the native extension. Tests assert against wafer-inc-duckling output — not the
Haskell/pyduckling format. A fixed reference time (2013-02-12 04:30:00 UTC-2,
matching the wafer-inc-duckling corpus) is passed via `reference_time:` to make
assertions deterministic. CI gets a Rust stable toolchain step.

Key decisions:
1. **Fixed reference time**: `REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")` — matches the corpus so test inputs and expected values can be read straight from [`corpus-cases.md`](../research/test-coverage/corpus-cases.md).
2. **NaiveDateTime format**: Bare ISO8601 without offset (per plan 02 Option N1). Test assertions use `start_with?` for date prefix matching.
3. **Latent default**: `Options::default()` has `with_latent: false` — latent entities excluded. Verified in research agent 1's correction to the briefing. ([wafer-inc-duckling-api/public-functions.md](../research/wafer-inc-duckling-api/public-functions.md))
4. **CI**: Add `dtolnay/rust-toolchain@stable` before the rake step. Default task already runs compile → test → standard after plan 01 Rakefile changes. ([ci-configuration.md](../research/build-wiring/ci-configuration.md))

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

### 1. `test/test_helper.rb` — Add reference constant and assertion helpers

```ruby
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")

module DucklingTimeAssertions
  def parse_time(text)
    Duckling.parse(text, locale: "en", dims: ["time"],
                   reference_time: REFERENCE_TIME.to_i)
  end

  def assert_time_naive(text, expected_date_prefix, expected_grain, msg = nil)
    result = parse_time(text)
    refute_empty result, "Expected parse result for #{text.inspect}"
    v = result.first["value"]
    assert_equal "value", v["type"], msg
    assert_equal expected_grain, v["grain"], msg
    assert v["value"].start_with?(expected_date_prefix),
      "#{v["value"].inspect} should start with #{expected_date_prefix.inspect}"
  end

  def assert_time_instant(text, expected_iso, expected_grain, msg = nil)
    result = parse_time(text)
    refute_empty result, "Expected parse result for #{text.inspect}"
    v = result.first["value"]
    assert_equal "value", v["type"], msg
    assert_equal expected_grain, v["grain"], msg
    assert_equal expected_iso, v["value"], msg
  end
end
```

### 2. `test/test_duckling.rb` — Replace placeholder, add test classes

Remove the existing `test_it_does_something_useful` (the `assert false` placeholder).
Replace with six test classes (each failing until the native extension is compiled):

```ruby
class TestDucklingVersion < Minitest::Test
  def test_version_number
    refute_nil ::Duckling::VERSION
  end
end

class TestDucklingParseTimeBasic < Minitest::Test
  include DucklingTimeAssertions

  def test_parse_today
    assert_time_naive "today", "2013-02-12", "day"
  end

  def test_parse_yesterday
    assert_time_naive "yesterday", "2013-02-11", "day"
  end

  def test_parse_tomorrow
    assert_time_naive "tomorrow", "2013-02-13", "day"
  end

  def test_parse_now
    # "now" → TimePoint::Instant at the reference time
    assert_time_instant "now", "2013-02-12T04:30:00-02:00", "second"
  end
end

class TestDucklingParseTimeWeekdays < Minitest::Test
  include DucklingTimeAssertions

  def test_parse_monday
    assert_time_naive "monday", "2013-02-18", "day"
  end

  def test_parse_friday
    assert_time_naive "friday", "2013-02-15", "day"
  end

  def test_parse_saturday
    assert_time_naive "saturday", "2013-02-16", "day"
  end
end

class TestDucklingParseTimeDates < Minitest::Test
  include DucklingTimeAssertions

  def test_parse_iso_date
    assert_time_naive "2015-03-03", "2015-03-03", "day"
  end

  def test_parse_us_slash_date
    assert_time_naive "3/3/2015", "2015-03-03", "day"
  end

  def test_parse_named_date
    assert_time_naive "march 3 2015", "2015-03-03", "day"
  end
end

class TestDucklingParseTimeRelative < Minitest::Test
  include DucklingTimeAssertions

  def test_parse_in_two_hours
    # 04:30 + 2h = 06:30, still on same day, Instant
    assert_time_instant "in 2 hours", "2013-02-12T06:30:00-02:00", "hour"
  end
end

class TestDucklingParseLatent < Minitest::Test
  def test_latent_excluded_by_default
    result = Duckling.parse("morning", locale: "en", dims: ["time"],
                            reference_time: REFERENCE_TIME.to_i)
    assert_empty result
  end
end
```

### 3. `.github/workflows/main.yml` — Add Rust toolchain step

Insert after the `ruby/setup-ruby` step and before `bundle exec rake`:

```yaml
- name: Set up Rust
  uses: dtolnay/rust-toolchain@stable
```

After plan 01's Rakefile changes, `bundle exec rake` runs `compile` then `test`
then `standard` — no separate compile step needed in CI.

### 4. VERSION bump — `lib/duckling/version.rb`

Change `VERSION = "0.1.0"` to `VERSION = "0.2.0"` (covered in plan 02 — noted
here for test-suite ordering: bump VERSION after tests are green).

### 5. RubyGems 0.2.0 publication (manual, post-CI green)

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

**Phase 1 — before native extension** (tests should fail):
```
bundle exec rake test
# → TestDucklingVersion: 1 pass
# → All time tests: Error (cannot load duckling/duckling)
```

**Phase 2 — after `bundle exec rake compile`** (all tests should pass):
```
bundle exec rake test
# → All tests pass
bundle exec rake standard
# → No offenses
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
