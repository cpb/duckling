# Corpus Cases: wafer-inc-duckling English Time Corpus

Source files examined:
- [`src/corpus/time_en.rs`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/corpus/time_en.rs) (92 KB, 1300+ lines)
- [`tests/time_corpus.rs`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/tests/time_corpus.rs) (5198 lines, 100+ `#[test]` functions)
- [`src/corpus/mod.rs`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/corpus/mod.rs) (corpus helper implementations)

---

## 1. Corpus Reference Setup

All English time corpus tests use a single fixed reference context defined at the top of `time_en.rs`:

```rust
// src/corpus/time_en.rs, lines 7-14
pub fn corpus() -> TrainingCorpus {
    let context = crate::resolve::Context::new(
        FixedOffset::west_opt(2 * 3600)
            .unwrap()
            .with_ymd_and_hms(2013, 2, 12, 4, 30, 0)
            .unwrap(),
        crate::locale::Locale::new(crate::locale::Lang::EN, None),
    );
```

And mirrored in the integration test file `tests/time_corpus.rs`, lines 33-38:

```rust
fn make_context() -> Context {
    context_at(
        local_datetime(-120, 2013, 2, 12, 4, 30, 0),
        Locale::new(Lang::EN, None),
    )
}
```

where `local_datetime(-120, ...)` means offset of -120 minutes = UTC-2.

**Reference time: 2013-02-12 04:30:00 UTC-2**

In Ruby terms:
```ruby
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")
```

The corpus options are `with_latent: false` (defined in `src/corpus/mod.rs` line 33), meaning latent entities are excluded from training. Integration tests also default to `Options::default()` which is `with_latent: false`.

The locale is `Lang::EN` with no region variant (`None`), equivalent to `"en"` in the Ruby API.

---

## 2. How Rust Test Helpers Work

All test helpers are defined in `tests/time_corpus.rs` lines 59-211. They call `parse()` and assert the result contains an entity matching expected values.

### `check_time_naive(text, expected_value: NaiveDateTime, expected_grain: &str)`

Asserts that parsing `text` produces at least one `TimeValue::Single` with a `TimePoint::Naive` variant whose `value == expected_value` and `grain == Grain::from_str(expected_grain)`.

Naive times are **wall-clock/calendar times with no timezone**. Examples: "tomorrow", "3pm", "March 15th".

```rust
fn check_time_naive(text: &str, expected_value: NaiveDateTime, expected_grain: &str) {
    let entities = parse_time(text);
    let eg = grain(expected_grain);
    let found = entities.iter().any(|e| {
        matches!(&e.value,
            DimensionValue::Time(TimeValue::Single {
                value: TimePoint::Naive { value, grain }, ..
            }) if *value == expected_value && *grain == eg
        )
    });
    assert!(found, ...);
}
```

### `check_time_instant(text, expected_value: NaiveDateTime, expected_grain: &str)`

Same structure but matches `TimePoint::Instant` (absolute offset-aware moment). The comparison uses `value.naive_local() == expected_value` — it strips the offset and compares the local wall-clock representation.

Instant times arise for: "now", "in 2 hours", "5 pm EST" (explicit timezone). The distinction: an instant is pinned to a real moment in time; a naive value is a calendar/clock reading without timezone.

### `check_time_interval(text, expected_from, expected_to, expected_grain)`

Asserts a `TimeValue::Interval { from: Some(...), to: Some(...) }`. Both endpoints are compared by naive local time.

### `check_time_open_interval_after` / `check_time_open_interval_before`

For half-open intervals like "after 3pm" (from only) and "before 5pm" (to only).

### `check_no_time(text)`

Asserts that parsing `text` produces zero `DimensionValue::Time` entities.

### What the assertions do NOT check

- `entity.latent` — the helpers do not verify the latent flag
- `entity.body` — the matched text span is not checked
- `entity.start` / `entity.end` — character offsets are not checked
- Other candidates in `TimeValue::Single { values: Vec<TimePoint> }` — only the primary `value` is checked

---

## 3. Corpus Cases by Category

### 3a. Now / Current (Instant, Grain: Second)

Reference: `2013-02-12 04:30:00` (exact reference moment)

```
"now"            -> 2013-02-12 04:30:00 [second]
"right now"      -> 2013-02-12 04:30:00 [second]
"just now"       -> 2013-02-12 04:30:00 [second]
"at the moment"  -> 2013-02-12 04:30:00 [second]
"ATM"            -> 2013-02-12 04:30:00 [second]
```

These are `TimePoint::Instant` — they resolve to the exact reference time as an absolute moment. In `tests/time_corpus.rs`: `test_time_now` (lines 217-223).

---

### 3b. Simple Relative Days (Naive, Grain: Day or Month/Year)

```
"today"           -> 2013-02-12 00:00:00 [day]
"at this time"    -> 2013-02-12 00:00:00 [day]
"yesterday"       -> 2013-02-11 00:00:00 [day]
"tomorrow"        -> 2013-02-13 00:00:00 [day]
"tomorrows"       -> 2013-02-13 00:00:00 [day]
"2/2013"          -> 2013-02-01 00:00:00 [month]
"in 2014"         -> 2014-01-01 00:00:00 [year]
```

Tests: `test_time_today`, `test_time_yesterday`, `test_time_tomorrow`, `test_time_month_year_slash`, `test_time_in_2014`.

Multi-step relative:
```
"last week"              -> 2013-02-04 [week]
"this week"              -> 2013-02-11 [week]
"next week"              -> 2013-02-18 [week]
"last month"             -> 2013-01-01 [month]
"next month"             -> 2013-03-01 [month]
"last year"              -> 2012-01-01 [year]
"this year"              -> 2013-01-01 [year]
"next year"              -> 2014-01-01 [year]
"the day after tomorrow" -> 2013-02-14 [day]
"the day before yesterday" -> 2013-02-10 [day]
"3 years from today"     -> 2016-02-12 [day]
```

---

### 3c. Named Weekdays (Naive, Grain: Day)

All resolve to the NEXT upcoming occurrence of that weekday from the reference date (Tuesday 2013-02-12):

```
"monday" / "mon." / "this monday" -> 2013-02-18 [day]
"tuesday" / "Tuesday the 19th"    -> 2013-02-19 [day]
"thursday" / "thu" / "thu."       -> 2013-02-14 [day]
"friday" / "fri" / "fri."         -> 2013-02-15 [day]
"saturday" / "sat" / "sat."       -> 2013-02-16 [day]
"sunday" / "sun" / "sun."         -> 2013-02-17 [day]
"Thu 15th"                         -> 2013-08-15 [day]  (disambiguated by date)
```

Note: "monday" resolves to 2013-02-18 (next Monday), not 2013-02-11 (this Monday) — the reference date is a Tuesday and the parser uses the next upcoming weekday by default.

Next/last qualifiers:
```
"next tuesday"            -> 2013-02-19 [day]
"next wednesday"          -> 2013-02-20 [day]
"last sunday"             -> 2013-02-10 [day]
"last tuesday"            -> 2013-02-05 [day]
"friday after next"       -> 2013-02-22 [day]
"wednesday of next week"  -> 2013-02-20 [day]
"monday of this week"     -> 2013-02-11 [day]
```

---

### 3d. Date Formats (Naive, Grain: Day)

Multi-format parsing for specific dates:

```
"march 3 2015"  / "march 3rd 2015" / "3/3/2015"
"3/3/15" / "2015-3-3" / "2015-03-03"
                    -> 2015-03-03 [day]

"on the 15th" / "february 15" / "February 15"
"the 15th of february" / "february the 15th"
"15 of february" / "15th february"
                    -> 2013-02-15 [day]

"march 3" / "the third of march"  -> 2013-03-03 [day]
"march first" / "first of march"  -> 2013-03-01 [day]
"the ides of march"               -> 2013-03-15 [day]
"Aug 8"                           -> 2013-08-08 [day]
"14april 2015" / "April 14, 2015" -> 2015-04-14 [day]
```

Month-year formats:
```
"October 2014" / "2014-10" / "2014/10"  -> 2014-10-01 [month]
```

---

### 3e. Time of Day (Naive, Grain: Hour or Minute or Second)

Absolute clock times:

```
"at 3am" / "at three am" / "3 in the morning" -> 2013-02-13 03:00:00 [hour]
"at 3pm" / "3PM" / "3pm approximately"        -> 2013-02-12 15:00:00 [hour]
"8 tonight" / "8 this evening"                -> 2013-02-12 20:00:00 [hour]
"this morning @ 10" / "this morning at 10am"  -> 2013-02-12 10:00:00 [hour]
```

Note: "at 3am" resolves to 2013-02-13 (next day) because 3am is before the reference time of 04:30. "at 3pm" resolves to 2013-02-12 (same day) because 3pm is after 04:30.

With minutes:
```
"3:15pm" / "3:15PM" / "15:15"                -> 2013-02-12 15:15:00 [minute]
"3:30pm" / "15:30" / "half past 3 pm"        -> 2013-02-12 15:30:00 [minute]
"a quarter to noon" / "11:45am"              -> 2013-02-12 11:45:00 [minute]
"a quarter past noon" / "12:15"              -> 2013-02-12 12:15:00 [minute]
```

With seconds:
```
"15:23:24"   -> 2013-02-12 15:23:24 [second]
"9:01:10 AM" -> 2013-02-12 09:01:10 [second]
```

24-hour formats:
```
"15h00" / "15h"    -> 2013-02-12 15:00:00 [minute]
"15h15"            -> 2013-02-12 15:15:00 [minute]
"15h30"            -> 2013-02-12 15:30:00 [minute]
```

---

### 3f. Relative Offsets (Instant, Grain varies)

Offsets from the reference time (04:30:00 on 2013-02-12):

```
"in a sec"          -> 2013-02-12 04:30:01 [second]   (Instant)
"in a minute"       -> 2013-02-12 04:31:00 [second]   (Instant)
"in 2 minutes"      -> 2013-02-12 04:32:00 [second]   (Instant)
"in a few minutes"  -> 2013-02-12 04:33:00 [second]   (Instant)
"in 60 minutes"     -> 2013-02-12 05:30:00 [second]   (Instant)
"in 1/4 hour"       -> 2013-02-12 04:45:00 [second]   (Instant)
"in half an hour"   -> 2013-02-12 05:00:00 [second]   (Instant)
"in one hour"       -> 2013-02-12 05:30:00 [minute]   (Instant)
"in 2.5 hours"      -> 2013-02-12 07:00:00 [second]   (Instant)
"in a few hours"    -> 2013-02-12 07:30:00 [minute]   (Instant)
"in 7 days"         -> 2013-02-19 04:00:00 [hour]     (Instant)
"in 1 week"         -> 2013-02-19 00:00:00 [day]      (Instant)
```

Past offsets:
```
"7 days ago"        -> 2013-02-05 04:00:00 [hour]     (Instant)
"a fortnight ago"   -> 2013-01-29 04:00:00 [hour]     (Instant)
"a week ago"        -> 2013-02-05 00:00:00 [day]      (Instant)
"three weeks ago"   -> 2013-01-22 00:00:00 [day]      (Instant)
"three months ago"  -> 2012-11-12 00:00:00 [day]      (Instant)
```

Note the grain difference: `"in 2 minutes"` resolves at Second grain, but `"in one hour"` resolves at Minute grain. This tracks with the precision of the expression.

Note also that "in 7 days" is Instant but "3 years from today" is Naive (the `today` anchor demotes it to a Naive day-grain result).

---

### 3g. Intervals (TimeValue::Interval, Grain varies)

Closed intervals (from + to):

```
"3-4pm" / "from 3 to 4 in the PM"
    -> 2013-02-12 15:00 to 2013-02-12 17:00 [hour]

"3:30 to 6 PM" / "3:30-6:00pm"
    -> 2013-02-12 15:30 to 2013-02-12 18:01 [minute]

"8am - 1pm"
    -> 2013-02-12 08:00 to 2013-02-12 14:00 [hour]

"July 13-15" / "from July 13 to 15"
    -> 2013-07-13 to 2013-07-16 [day]

"from 9:30 - 11:00 on Thursday" / "between 9:30 and 11:00 on thursday"
    -> 2013-02-14 09:30 to 2013-02-14 11:01 [minute]

"last 2 days"     -> 2013-02-10 to 2013-02-12 [day]
"next 3 days"     -> 2013-02-13 to 2013-02-16 [day]
"last 2 weeks"    -> 2013-01-28 to 2013-02-11 [week]
"this Summer"     -> 2013-06-21 to 2013-09-24 [day]
"this winter"     -> 2012-12-21 to 2013-03-21 [day]
"this evening" / "tonight"
    -> 2013-02-12 18:00 to 2013-02-13 00:00 [hour]
"last night"      -> 2013-02-11 18:00 to 2013-02-12 00:00 [hour]
```

Open intervals:
```
"by 2:00pm"       -> from 2013-02-12 04:30 to 2013-02-12 14:00 [second]
"by EOD"          -> from 2013-02-12 04:30 to 2013-02-13 00:00 [second]
"by EOM"          -> from 2013-02-12 04:30 to 2013-03-01 00:00 [second]
"Within 2 weeks"  -> from 2013-02-12 04:30 to 2013-02-26 00:00 [second]
```

---

### 3h. Latent Entities

The English time corpus (`time_en.rs`) does not define explicit latent test cases. The `build_corpus` function in `src/corpus/mod.rs` (line 33) sets `with_latent: false`, which excludes latent entities from training.

The `latent` field on `Entity` is `Option<bool>`. The test helper functions (`check_time_naive`, `check_time_instant`, etc.) do not assert on the latent flag.

From wafer-inc-duckling's README: an explicit timezone (e.g. "3pm CET") promotes a naive time to an instant. Conversely, bare hour references without AM/PM disambiguation may produce latent entities (e.g. parsing "3" alone as a time without context). The `with_latent: true` option in `Options` enables these to appear in results.

The pyduckling API exposes this as the 4th argument to `parse()`:
```python
parse('En dos semanas', context, dims, False)  # with_latent=False
```

For Ruby minitest, latent behavior should be tested separately with `with_latent: true` and `with_latent: false` options (see `ruby-test-design.md`).

---

### 3i. Holidays and Special Days

The corpus also covers holidays via `datetime_holiday` (which maps to `datetime` in the Rust implementation — the holiday name is not separately checked):

```
"xmas" / "christmas" / "christmas day"   -> 2013-12-25 [day]
"new year's eve"                          -> 2013-12-31 [day]
"new year's day"                          -> 2014-01-01 [day]
"valentine's day"                         -> 2013-02-14 [day]
"4th of July"                             -> 2013-07-04 [day]
"halloween"                               -> 2013-10-31 [day]
"black friday"                            -> 2013-11-29 [day]
"easter" / "easter 2013"                  -> 2013-03-31 [day]
"mardi gras" / "pancake day 2013"         -> 2013-02-12 [day]
```

These are lower priority for Ruby 0.2.0 since they depend on holiday calendar logic in wafer-inc-duckling and are not core to the time extraction API shape.

---

### 3j. Quarters

```
"this quarter" / "this qtr"  -> 2013-01-01 [quarter]
"next quarter"               -> 2013-04-01 [quarter]
"third quarter"              -> 2013-07-01 [quarter]
"4th quarter 2018" / "2018Q4" / "18q4"  -> 2018-10-01 [quarter]
```

---

## 4. Corpus Size and Coverage

From reading `time_en.rs` and `tests/time_corpus.rs`:

| Category | Corpus entries (approx.) | Integration tests |
|---|---|---|
| Now/current | 5 texts | 1 test |
| Simple relative days/weeks/months/years | 30+ texts | 15+ tests |
| Named weekdays | 25+ texts | 13 tests |
| Date formats | 40+ texts | 10+ tests |
| Time of day | 100+ texts | 20+ tests |
| Relative offsets (future) | 40+ texts | 15+ tests |
| Relative offsets (past) | 20+ texts | 8 tests |
| Intervals (closed) | 80+ texts | 20+ tests |
| Intervals (open) | 15+ texts | 5 tests |
| Quarters | 15+ texts | 4 tests |
| Holidays | 50+ texts | not separately counted |
| N-th weekday of month | 20+ texts | 10 tests |

The full `tests/time_corpus.rs` file has 5198 lines with approximately 100+ `#[test]` functions organized one-group-per-function.
