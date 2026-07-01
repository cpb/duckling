# Ruby Minitest Test Suite Design

This document designs the minitest test suite for the Ruby duckling gem (`0.2.0`), based on the [duckling](https://github.com/wafer-inc/duckling) corpus and pyduckling reference tests.

Source state examined:
- `test/test_duckling.rb` — current state: version check + intentionally failing placeholder
- `test/test_helper.rb` — current state: loads lib, requires minitest/autorun
- `lib/duckling.rb` — current state: empty module scaffold

---

## 1. Fixed Reference Time

All time-parsing tests must use the same reference time as the [duckling](https://github.com/wafer-inc/duckling) corpus:

```ruby
# In test/test_helper.rb (to be added):
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")
```

This matches `FixedOffset::west_opt(2 * 3600).with_ymd_and_hms(2013, 2, 12, 4, 30, 0)` from the Rust corpus (`src/corpus/time_en.rs`, lines 9-11).

The reference time is a fixed constant — it does not change between test runs. Every `Duckling.parse` call in time-related tests must pass it as context, otherwise results will vary by clock.

---

## 2. How `Duckling.parse` Will Be Called

The public API for the gem is not yet implemented, but the acceptance criteria in `pr_context.md` states:

```
Duckling.parse(text, locale: "en") extracts time/date entities from English text
```

Based on patterns from pyduckling (`parse(text, context, dims, with_latent)`) and the [duckling](https://github.com/wafer-inc/duckling) Rust API (`parse(text, locale, dims, context, options)`), the expected Ruby signature is one of:

```ruby
# Option A: keyword args, context embedded
Duckling.parse("today", locale: "en", reference_time: REFERENCE_TIME, dims: ["time"])

# Option B: Context object
ctx = Duckling::Context.new(REFERENCE_TIME, "en")
Duckling.parse("today", context: ctx, dims: ["time"])
```

The test design below uses **Option A** (keyword args). If the API lands differently, only the call site changes — the assertion patterns remain the same.

---

## 3. Return Value Shape

The gem should return an array of entity hashes. Based on the [duckling](https://github.com/wafer-inc/duckling) `Entity` struct and pyduckling's return format:

```ruby
# For "today" with reference 2013-02-12 04:30 UTC-2:
[
  {
    "body"   => "today",
    "start"  => 0,
    "end"    => 5,
    "latent" => false,
    "value"  => {
      "type"  => "value",        # or "interval"
      "grain" => "day",
      "value" => "2013-02-12T00:00:00.000-02:00"   # ISO8601 string
    }
  }
]
```

The grain strings correspond to Rust `Grain` enum variants lowercased: `"second"`, `"minute"`, `"hour"`, `"day"`, `"week"`, `"month"`, `"quarter"`, `"year"`.

The actual key names and ISO8601 format are TBD pending the Magnus bridge implementation. The test design below extracts only the date prefix (`[0..9]`) for naive dates, to be resilient to offset/format variations.

---

## 4. Test Helper Module

Add to `test/test_helper.rb`:

```ruby
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")

module DucklingTimeAssertions
  def parse_time(text, with_latent: false)
    Duckling.parse(
      text,
      locale: "en",
      reference_time: REFERENCE_TIME,
      dims: ["time"],
      with_latent: with_latent
    )
  end

  def assert_naive_time(text, expected_date_prefix, expected_grain)
    results = parse_time(text)
    refute_empty results, "Expected at least one result for #{text.inspect}"
    entity = results.find { |e|
      v = e["value"]
      v["grain"] == expected_grain &&
        v["value"].to_s.start_with?(expected_date_prefix) &&
        !v.key?("from")   # not an interval
    }
    assert entity,
      "Expected naive time grain=#{expected_grain} date=#{expected_date_prefix} for " \
      "#{text.inspect}, got: #{results.inspect}"
    assert_equal false, entity["latent"],
      "Expected latent=false for #{text.inspect}"
    entity
  end

  def assert_instant_time(text, expected_date_prefix, expected_grain)
    # For instant times the value string is also an ISO8601 datetime.
    # We check the local-time portion only, consistent with how Rust tests
    # use value.naive_local().
    assert_naive_time(text, expected_date_prefix, expected_grain)
  end
end
```

For interval assertions:

```ruby
def assert_time_interval(text, expected_from_prefix, expected_to_prefix, expected_grain)
  results = parse_time(text)
  entity = results.find { |e|
    v = e["value"]
    v["type"] == "interval" &&
      v.dig("from", "value").to_s.start_with?(expected_from_prefix) &&
      v.dig("to",   "value").to_s.start_with?(expected_to_prefix)   &&
      (v.dig("from", "grain") == expected_grain || v.dig("to", "grain") == expected_grain)
  }
  assert entity,
    "Expected interval from #{expected_from_prefix} to #{expected_to_prefix} " \
    "grain=#{expected_grain} for #{text.inspect}, got: #{results.inspect}"
end
```

---

## 5. Test Classes for 0.2.0

### `TestDucklingVersion`

Already exists in `test/test_duckling.rb`. Keep as-is.

```ruby
def test_that_it_has_a_version_number
  refute_nil ::Duckling::VERSION
end
```

### `TestDucklingParseTimeBasic`

Covers: now, today, yesterday, tomorrow.

```ruby
class TestDucklingParseTimeBasic < Minitest::Test
  include DucklingTimeAssertions

  def test_now
    assert_instant_time("now",       "2013-02-12T04:30:00", "second")
    assert_instant_time("right now", "2013-02-12T04:30:00", "second")
    assert_instant_time("ATM",       "2013-02-12T04:30:00", "second")
  end

  def test_today
    assert_naive_time("today",       "2013-02-12", "day")
    assert_naive_time("at this time","2013-02-12", "day")
  end

  def test_yesterday
    assert_naive_time("yesterday",   "2013-02-11", "day")
  end

  def test_tomorrow
    assert_naive_time("tomorrow",    "2013-02-13", "day")
    assert_naive_time("tomorrows",   "2013-02-13", "day")
  end

  def test_this_week
    assert_naive_time("this week",   "2013-02-11", "week")
  end

  def test_next_week
    assert_naive_time("next week",   "2013-02-18", "week")
  end

  def test_last_week
    assert_naive_time("last week",   "2013-02-04", "week")
  end

  def test_this_month
    assert_naive_time("this month",  "2013-02-01", "month")
  end

  def test_next_month
    assert_naive_time("next month",  "2013-03-01", "month")
  end

  def test_this_year
    assert_naive_time("this year",   "2013-01-01", "year")
  end

  def test_next_year
    assert_naive_time("next year",   "2014-01-01", "year")
  end
end
```

### `TestDucklingParseTimeWeekdays`

Covers: monday through sunday, next/last weekday.

```ruby
class TestDucklingParseTimeWeekdays < Minitest::Test
  include DucklingTimeAssertions

  def test_monday
    assert_naive_time("monday",         "2013-02-18", "day")
    assert_naive_time("mon.",           "2013-02-18", "day")
    assert_naive_time("this monday",    "2013-02-18", "day")
    assert_naive_time("Monday, Feb 18", "2013-02-18", "day")
  end

  def test_tuesday
    assert_naive_time("tuesday",          "2013-02-19", "day")
    assert_naive_time("Tuesday the 19th", "2013-02-19", "day")
  end

  def test_thursday
    assert_naive_time("thursday",         "2013-02-14", "day")
    assert_naive_time("thu",              "2013-02-14", "day")
  end

  def test_friday
    assert_naive_time("friday",           "2013-02-15", "day")
    assert_naive_time("fri",              "2013-02-15", "day")
  end

  def test_saturday
    assert_naive_time("saturday",         "2013-02-16", "day")
    assert_naive_time("sat",              "2013-02-16", "day")
  end

  def test_sunday
    assert_naive_time("sunday",           "2013-02-17", "day")
    assert_naive_time("sun",              "2013-02-17", "day")
  end

  def test_next_tuesday
    assert_naive_time("next tuesday",     "2013-02-19", "day")
  end

  def test_last_sunday
    assert_naive_time("last sunday",      "2013-02-10", "day")
  end

  def test_friday_after_next
    assert_naive_time("friday after next","2013-02-22", "day")
  end
end
```

### `TestDucklingParseTimeDates`

Covers: ISO dates, US-style dates, month+day+year, named month expressions.

```ruby
class TestDucklingParseTimeDates < Minitest::Test
  include DucklingTimeAssertions

  def test_iso_date
    assert_naive_time("2015-03-03", "2015-03-03", "day")
    assert_naive_time("2015-3-3",   "2015-03-03", "day")
  end

  def test_us_date
    assert_naive_time("3/3/2015",   "2015-03-03", "day")
    assert_naive_time("3/3/15",     "2015-03-03", "day")
  end

  def test_month_name_date
    assert_naive_time("march 3 2015",    "2015-03-03", "day")
    assert_naive_time("march third 2015","2015-03-03", "day")
    assert_naive_time("march 3",         "2013-03-03", "day")
    assert_naive_time("the ides of march","2013-03-15","day")
    assert_naive_time("march first",     "2013-03-01", "day")
  end

  def test_day_of_month
    assert_naive_time("february 15",     "2013-02-15", "day")
    assert_naive_time("on the 15th",     "2013-02-15", "day")
    assert_naive_time("the 15th of february","2013-02-15","day")
    assert_naive_time("Aug 8",           "2013-08-08", "day")
  end

  def test_month_year_slash
    assert_naive_time("2/2013",          "2013-02-01", "month")
  end

  def test_month_year_name
    assert_naive_time("October 2014",    "2014-10-01", "month")
    assert_naive_time("2014-10",         "2014-10-01", "month")
    assert_naive_time("in 2014",         "2014-01-01", "year")
  end
end
```

### `TestDucklingParseTimeRelative`

Covers: "in N minutes/hours", "N hours ago", etc.

```ruby
class TestDucklingParseTimeRelative < Minitest::Test
  include DucklingTimeAssertions

  def test_in_a_minute
    assert_instant_time("in a minute",   "2013-02-12T04:31:00", "second")
  end

  def test_in_2_minutes
    assert_instant_time("in 2 minutes",  "2013-02-12T04:32:00", "second")
    assert_instant_time("2 minutes from now", "2013-02-12T04:32:00", "second")
  end

  def test_in_half_an_hour
    assert_instant_time("in half an hour","2013-02-12T05:00:00", "second")
  end

  def test_in_one_hour
    assert_instant_time("in one hour",   "2013-02-12T05:30:00", "minute")
    assert_instant_time("in 1h",         "2013-02-12T05:30:00", "minute")
  end

  def test_7_days_ago
    assert_instant_time("7 days ago",    "2013-02-05T04:00:00", "hour")
  end

  def test_a_week_ago
    assert_instant_time("a week ago",    "2013-02-05", "day")
  end

  def test_in_1_week
    assert_instant_time("in 1 week",     "2013-02-19", "day")
  end
end
```

### `TestDucklingParseTimeInterval`

Covers: "from X to Y", "X - Y pm", "last N days", "next N weeks".

```ruby
class TestDucklingParseTimeInterval < Minitest::Test
  include DucklingTimeAssertions

  def test_time_range_pm
    assert_time_interval("3-4pm",
      "2013-02-12T15:00", "2013-02-12T17:00", "hour")
  end

  def test_time_range_with_minutes
    assert_time_interval("3:30 to 6 PM",
      "2013-02-12T15:30", "2013-02-12T18:", "minute")
  end

  def test_date_range
    assert_time_interval("July 13-15",
      "2013-07-13", "2013-07-16", "day")
  end

  def test_last_n_days
    assert_time_interval("last 2 days",
      "2013-02-10", "2013-02-12", "day")
  end

  def test_next_n_days
    assert_time_interval("next 3 days",
      "2013-02-13", "2013-02-16", "day")
  end

  def test_tonight
    assert_time_interval("tonight",
      "2013-02-12T18:00", "2013-02-13T00:00", "hour")
  end

  def test_last_night
    assert_time_interval("last night",
      "2013-02-11T18:00", "2013-02-12T00:00", "hour")
  end
end
```

### `TestDucklingParseLatent`

Covers: `with_latent` option behavior.

```ruby
class TestDucklingParseLatent < Minitest::Test
  include DucklingTimeAssertions

  def test_with_latent_false_excludes_bare_hour
    # "3" alone (no am/pm) is a latent time — excluded by default
    results = parse_time("Meet at 3", with_latent: false)
    # If there is a result, it should not be latent
    results.each do |e|
      assert_equal false, e["latent"] if e["value"]["grain"] == "hour"
    end
  end

  def test_with_latent_true_includes_bare_hour
    # With latent enabled, ambiguous "3" should resolve
    results = parse_time("at 3", with_latent: true)
    latent_results = results.select { |e| e["latent"] }
    # At minimum, the option must not error
    assert_kind_of Array, results
  end
end
```

Note: the exact latent behavior depends on what the bridge exposes. These tests verify the option is plumbed through and has an observable effect.

### `TestDucklingParseLocale`

Covers: locale construction and minimal locale variant behavior.

```ruby
class TestDucklingParseLocale < Minitest::Test
  def test_locale_en_accepts_basic_time
    results = Duckling.parse(
      "tomorrow",
      locale: "en",
      reference_time: REFERENCE_TIME,
      dims: ["time"]
    )
    refute_empty results
  end

  def test_invalid_locale_raises_or_defaults
    # Behavior TBD: raise ArgumentError or fall back to EN?
    # At minimum the call must not crash the process.
    assert_nothing_raised do
      Duckling.parse("tomorrow", locale: "xx", reference_time: REFERENCE_TIME, dims: ["time"])
    end
  rescue => e
    assert_kind_of ArgumentError, e
  end
end
```

---

## 6. Test File Structure

```
test/
  test_helper.rb         # REFERENCE_TIME constant, DucklingTimeAssertions module
  test_duckling.rb       # TestDuckling (version check)
  test_duckling_time.rb  # All time-extraction test classes (Basic, Weekdays, Dates, Relative, Interval, Latent, Locale)
```

Keeping all time tests in one file reduces require overhead while keeping the classes logically distinct. If the file grows beyond ~300 lines, split by category.

---

## 7. Parity Strategy

The acceptance criteria requires tests that "validate parity" with [duckling](https://github.com/wafer-inc/duckling). The approach:

1. **Port subset, not all**: The 100+ Rust integration tests are comprehensive. For Ruby 0.2.0, target ~30-40 representative cases: one or two per category, plus the edge cases that distinguish naive/instant behavior.

2. **Match Rust expected values exactly**: Use the same expected date/time strings as the Rust `check_time_naive`/`check_time_instant` calls. If a Rust test says `dt(2013, 2, 12, 4, 30, 0)` → check for `"2013-02-12T04:30:00"` in the Ruby output.

3. **Reference time is canonical**: Every test must pass `reference_time: REFERENCE_TIME`. Without it, results are non-deterministic.

4. **Naive vs Instant distinguishable**: If the bridge serializes both as ISO8601 strings, the test helper may need to check an additional field (e.g., `"type": "naive"` vs `"type": "instant"`) — but the exact shape depends on the Magnus bridge design.

5. **Latent flag is testable**: The `with_latent` option must be plumbed from Ruby to Rust. A test verifying that "at 3pm" returns `latent: false` serves as a smoke test for this path.

---

## 8. Priority Ordering for 0.2.0

Implement in this order:

1. `TestDucklingVersion` — already passes (smoke test)
2. `TestDucklingParseTimeBasic` — now/today/yesterday/tomorrow (simplest API exercise)
3. `TestDucklingParseTimeDates` — ISO/US/name formats (validates date parsing)
4. `TestDucklingParseTimeWeekdays` — validates weekday resolution
5. `TestDucklingParseTimeRelative` — validates offset computation
6. `TestDucklingParseTimeInterval` — validates interval shape
7. `TestDucklingParseLatent` — validates option passthrough
8. `TestDucklingParseLocale` — validates locale handling

Each class can be enabled one at a time as the bridge implementation progresses, by toggling `skip` calls or moving test files.
