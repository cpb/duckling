# frozen_string_literal: true

require "test_helper"

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00, a Tuesday), so relative expressions
# resolve to fixed, assertable values instead of drifting with the real clock.
# See test/duckling_test.rb for the same convention. Guarded with `unless
# defined?` since this file may load in the same process as duckling_test.rb
# (which defines the same top-level constant) via `bundle exec rake test`, or
# standalone via `bin/test test/duckling_time_test.rb`.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i unless defined?(REFERENCE_TIME)

# Extended coverage for basic relative-time resolution, mirroring the
# wafer-inc-duckling / pyduckling en time corpus: now, today, yesterday,
# tomorrow, and this/next/last week, month, and year.
class TestDucklingParseTimeBasic < Minitest::Test
  def time_entity_for(text)
    results = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for #{text.inspect}, got: #{results.inspect}"
    entity
  end

  def test_now
    entity = time_entity_for("now")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T04:30:00", entity[:value][:value]
  end

  def test_today
    entity = time_entity_for("today")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-12T00:00:00", entity[:value][:value]
  end

  def test_yesterday
    entity = time_entity_for("yesterday")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-11T00:00:00", entity[:value][:value]
  end

  def test_tomorrow
    entity = time_entity_for("tomorrow")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-13T00:00:00", entity[:value][:value]
  end

  def test_this_week
    entity = time_entity_for("this week")
    assert_equal :value, entity[:value][:type]
    assert_equal :week, entity[:value][:grain]
    # Week containing 2013-02-12 (Tuesday) starts Monday 2013-02-11.
    assert_equal "2013-02-11T00:00:00", entity[:value][:value]
  end

  def test_next_week
    entity = time_entity_for("next week")
    assert_equal :value, entity[:value][:type]
    assert_equal :week, entity[:value][:grain]
    assert_equal "2013-02-18T00:00:00", entity[:value][:value]
  end

  def test_last_week
    entity = time_entity_for("last week")
    assert_equal :value, entity[:value][:type]
    assert_equal :week, entity[:value][:grain]
    assert_equal "2013-02-04T00:00:00", entity[:value][:value]
  end

  def test_this_month
    entity = time_entity_for("this month")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal "2013-02-01T00:00:00", entity[:value][:value]
  end

  def test_next_month
    entity = time_entity_for("next month")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal "2013-03-01T00:00:00", entity[:value][:value]
  end

  def test_last_month
    entity = time_entity_for("last month")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal "2013-01-01T00:00:00", entity[:value][:value]
  end

  def test_this_year
    entity = time_entity_for("this year")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal "2013-01-01T00:00:00", entity[:value][:value]
  end

  def test_next_year
    entity = time_entity_for("next year")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal "2014-01-01T00:00:00", entity[:value][:value]
  end

  def test_last_year
    entity = time_entity_for("last year")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal "2012-01-01T00:00:00", entity[:value][:value]
  end
end

# Extended corpus for bare/relative weekday parsing, ported from the kind of
# cases the Ruby port's design docs point at in the original Haskell/pyduckling
# corpus (`Duckling.Time.EN.Corpus`) — bare weekday names, abbreviations, and
# "next/last/after next <weekday>" relative expressions.
#
# Expected values below were cross-checked against the wrapped Rust crate's
# OWN training corpus (`duckling-0.4.0/src/corpus/time_en.rs`, which uses the
# identical reference moment 2013-02-12T04:30:00-02:00), not just reasoned
# about from first principles, so they reflect the ground truth this gem is
# supposed to expose, not just plausible guesses.
#
# Reference date: 2013-02-12T04:30:00-02:00 is a TUESDAY. A bare weekday name
# resolves to the *strictly next* occurrence of that weekday STRICTLY AFTER
# the reference date — today itself is never returned, even for "tuesday"
# (see test_bare_tuesday_on_the_reference_weekday, confirmed against
# time_en.rs's own `datetime(2013, 2, 19, ...) => ["tuesday", ...]` case):
#
#   Mon 2013-02-11 (before ref) < TUE 2013-02-12 (ref, excluded) < Wed 02-13
#   < Thu 02-14 < Fri 02-15 < Sat 02-16 < Sun 02-17 < Mon 02-18 (next week)
#   < Tue 02-19 (next week)
class TestDucklingParseTimeWeekdays < Minitest::Test
  def time_entity(text)
    results = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME)
    results.find { |r| r[:dim] == :time }
  end

  def assert_time_value(expected_iso, text, grain: :day)
    entity = time_entity(text)
    refute_nil entity, "Expected a :time entity for #{text.inspect}"
    assert_equal :value, entity[:value][:type], "Expected a :value type for #{text.inspect}"
    assert_equal grain, entity[:value][:grain], "Expected grain #{grain.inspect} for #{text.inspect}"
    assert_equal expected_iso, entity[:value][:value], "Wrong resolved date for #{text.inspect}"
  end

  # -- bare weekday names ---------------------------------------------------

  def test_bare_monday_resolves_to_next_monday
    # This week's Monday (02-11) is already before the reference date, so the
    # nearest strictly-future Monday is next week's.
    assert_time_value "2013-02-18T00:00:00", "monday"
  end

  def test_bare_wednesday_resolves_to_this_week
    assert_time_value "2013-02-13T00:00:00", "wednesday"
  end

  def test_bare_thursday_resolves_to_this_week
    assert_time_value "2013-02-14T00:00:00", "thursday"
  end

  def test_bare_friday_resolves_to_this_week
    assert_time_value "2013-02-15T00:00:00", "friday"
  end

  def test_bare_saturday_resolves_to_this_week
    assert_time_value "2013-02-16T00:00:00", "saturday"
  end

  def test_bare_sunday_resolves_to_this_week
    assert_time_value "2013-02-17T00:00:00", "sunday"
  end

  # Tuesday collides with the reference date's own weekday. Per
  # duckling-0.4.0/src/corpus/time_en.rs (`datetime(2013, 2, 19, ...) =>
  # vec!["tuesday", "Tuesday the 19th", "Tuesday 19th"]`), a bare mention of
  # today's own weekday does NOT resolve to today — it skips forward a full
  # week, same as if today's occurrence didn't exist at all.
  def test_bare_tuesday_on_the_reference_weekday
    assert_time_value "2013-02-19T00:00:00", "tuesday"
  end

  # -- abbreviations ---------------------------------------------------------

  def test_abbreviation_mon_resolves_like_monday
    assert_time_value "2013-02-18T00:00:00", "mon"
  end

  def test_abbreviation_tue_resolves_like_tuesday
    assert_time_value "2013-02-19T00:00:00", "tue"
  end

  def test_abbreviation_wed_resolves_like_wednesday
    assert_time_value "2013-02-13T00:00:00", "wed"
  end

  def test_abbreviation_thu_resolves_like_thursday
    assert_time_value "2013-02-14T00:00:00", "thu"
  end

  def test_abbreviation_fri_resolves_like_friday
    assert_time_value "2013-02-15T00:00:00", "fri"
  end

  def test_abbreviation_sat_resolves_like_saturday
    assert_time_value "2013-02-16T00:00:00", "sat"
  end

  def test_abbreviation_sun_resolves_like_sunday
    assert_time_value "2013-02-17T00:00:00", "sun"
  end

  # -- "next <weekday>" -------------------------------------------------------
  #
  # Per duckling-0.4.0/src/dimensions/time/en.rs's "next <time>" rule
  # (`not_immediate = true`), "next <weekday>" is supposed to skip past the
  # *nearest* strictly-future occurrence and land on the one after — one full
  # week later than the bare weekday name resolves to. This is confirmed
  # correct, for weekdays that still have an occurrence later in the
  # reference week, by time_en.rs's own corpus: bare "wednesday" => 02-13,
  # but "next wednesday" / "wednesday of next week" / "wednesday after next"
  # => 02-20; "friday after next" => 02-22, one week past what bare "friday"
  # resolves to (02-15).
  #
  # See test_current_actual_next_monday_does_not_skip_past_bare_monday /
  # test_next_monday_should_skip_to_the_following_monday below for a case
  # (Monday) where the gem does NOT reproduce this skip-forward behavior.

  def test_next_thursday_skips_past_this_weeks_thursday
    assert_time_value "2013-02-21T00:00:00", "next thursday"
  end

  def test_next_sunday_skips_past_this_weeks_sunday
    assert_time_value "2013-02-24T00:00:00", "next sunday"
  end

  # -- "last <weekday>" --------------------------------------------------------

  def test_last_monday_resolves_to_the_prior_week
    assert_time_value "2013-02-11T00:00:00", "last monday"
  end

  def test_last_thursday_resolves_to_the_prior_week
    assert_time_value "2013-02-07T00:00:00", "last thursday"
  end

  def test_last_sunday_resolves_to_the_prior_week
    # Confirmed against time_en.rs: datetime(2013, 2, 10, ...) =>
    # vec!["last sunday", "sunday from last week", "last week's sunday"].
    assert_time_value "2013-02-10T00:00:00", "last sunday"
  end

  # -- "<weekday> after next" --------------------------------------------------
  #
  # Per duckling-0.4.0/src/dimensions/time/en.rs's "<time> before last|after
  # next" rule (`Direction::FarFuture`), and confirmed by time_en.rs's own
  # corpus (`datetime(2013, 2, 22, ...) => vec!["friday after next"]`, one
  # week past bare "friday"'s 02-15), "<weekday> after next" is supposed to
  # behave the same as "next <weekday>" for weekdays that still have an
  # occurrence later in the reference week — i.e. skip forward one week past
  # the bare weekday value.

  def test_thursday_after_next_skips_past_this_weeks_thursday
    assert_time_value "2013-02-21T00:00:00", "thursday after next"
  end

  # -- known gap: "next monday" / "monday after next" -------------------------
  #
  # Genuine behavior gap, not a corpus-assumption mistake: Monday is the one
  # weekday that has ALREADY passed within the reference week (this week's
  # Monday, 02-11, is before the 2013-02-12 Tuesday reference), so bare
  # "monday" already resolves to *next* week (02-18, per
  # test_bare_monday_resolves_to_next_monday above).
  #
  # For every OTHER weekday tested above (Wednesday, Thursday, Friday, Sunday
  # — all still upcoming within the reference week), "next <weekday>" and
  # "<weekday> after next" correctly skip past the bare value by an
  # additional full week (see test_next_thursday_skips_past_this_weeks_thursday,
  # test_next_sunday_skips_past_this_weeks_sunday,
  # test_thursday_after_next_skips_past_this_weeks_thursday above). For
  # Monday specifically, they do not: this gem's Duckling.parse returns the
  # exact same date (02-18) for "monday", "next monday", and "monday after
  # next" alike, instead of skipping "next"/"after next" forward to 02-25 the
  # way the not_immediate / FarFuture direction rules (ext/duckling wraps
  # duckling-0.4.0's src/dimensions/time/en.rs) are documented to behave, and
  # the way they verifiably do for every other weekday in this file.
  #
  # Each case is documented as a pair of tests, mirroring the pattern in
  # test/duckling_comma_list_test.rb:
  #   - `test_current_actual_*` — passing, pins today's real (buggy) output.
  #   - `test_*` (skipped) — asserts the semantically correct output (one
  #     week past bare "monday"). Delete the `skip` line once
  #     `test_current_actual_*` starts failing, to confirm a fix landed.

  def test_current_actual_next_monday_does_not_skip_past_bare_monday
    entity = time_entity("next monday")
    assert_equal "2013-02-18T00:00:00", entity[:value][:value]
  end

  def test_next_monday_should_skip_to_the_following_monday
    skip "known gap: 'next monday' does not skip past bare 'monday' the way 'next <other weekday>' does (see file comment above)"

    entity = time_entity("next monday")
    assert_equal "2013-02-25T00:00:00", entity[:value][:value]
  end

  def test_current_actual_monday_after_next_does_not_skip_past_bare_monday
    entity = time_entity("monday after next")
    assert_equal "2013-02-18T00:00:00", entity[:value][:value]
  end

  def test_monday_after_next_should_skip_to_the_following_monday
    skip "known gap: 'monday after next' does not skip past bare 'monday' the way '<other weekday> after next' does (see file comment above)"

    entity = time_entity("monday after next")
    assert_equal "2013-02-25T00:00:00", entity[:value][:value]
  end
end

# Extended corpus for absolute date expressions, ported in spirit from the
# Ruby/Haskell/Rust duckling test suites' `TimeCorpus` date coverage: ISO
# dates, short ISO dates, US-style slash dates, month-name dates (with and
# without an explicit year), day-of-month expressions, and month/year-only
# forms. Matches the reference time used throughout the rest of this gem's
# test suite (2013-02-12T04:30:00-02:00), so relative/implied-year
# expressions resolve to fixed, assertable values.
class TestDucklingParseTimeDates < Minitest::Test
  def first_time_entity(text)
    results = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for #{text.inspect}, got: #{results.inspect}"
    entity
  end

  def test_iso_date
    entity = first_time_entity("2015-03-03")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2015-03-03T00:00:00", entity[:value][:value]
  end

  def test_short_iso_date
    entity = first_time_entity("2015-3-3")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2015-03-03T00:00:00", entity[:value][:value]
  end

  def test_us_slash_date_full_year
    entity = first_time_entity("3/3/2015")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2015-03-03T00:00:00", entity[:value][:value]
  end

  def test_us_slash_date_two_digit_year
    entity = first_time_entity("3/3/15")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2015-03-03T00:00:00", entity[:value][:value]
  end

  def test_month_name_date_with_explicit_year
    entity = first_time_entity("march 3 2015")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2015-03-03T00:00:00", entity[:value][:value]
  end

  def test_month_name_date_implied_current_year
    entity = first_time_entity("march 3")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    # No year specified — should resolve against REFERENCE_TIME's year (2013).
    assert_equal "2013-03-03T00:00:00", entity[:value][:value]
  end

  def test_day_of_month_month_then_day
    entity = first_time_entity("february 15")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-15T00:00:00", entity[:value][:value]
  end

  def test_day_of_month_ordinal_of_month
    entity = first_time_entity("the 15th of february")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-15T00:00:00", entity[:value][:value]
  end

  def test_numeric_month_slash_year
    entity = first_time_entity("2/2013")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal "2013-02-01T00:00:00", entity[:value][:value]
  end

  def test_month_name_and_year
    entity = first_time_entity("October 2014")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal "2014-10-01T00:00:00", entity[:value][:value]
  end

  def test_year_only
    entity = first_time_entity("in 2014")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal "2014-01-01T00:00:00", entity[:value][:value]
  end
end

# Extended corpus of relative-time expressions, ported from the intent of the
# Ruby test design doc for issue #34. Reference time matches the rest of the
# suite (2013-02-12T04:30:00-02:00) so relative expressions resolve to fixed,
# assertable values. Expected :value/:grain pairs below are taken directly
# from the wrapped Rust crate's own ground-truth corpus
# (~/.cargo/registry/src/*/duckling-0.4.0/tests/time_corpus.rs, e.g.
# `test_time_in_a_minute`, `test_time_in_one_hour`, `test_time_7_days_ago`,
# `test_time_a_week_ago`, `test_time_in_1_week`), not guessed.
#
# KNOWN BUG, confirmed by reading this gem's own binding source (not
# guessed): every test below whose expression resolves to a
# `TimePoint::Instant` (i.e. everything in this file — relative
# second/minute/hour/day offsets from "now") fails today, in two ways:
#
# 1. `ext/duckling/src/lib.rs`'s `build_context` turns the `reference_time:`
#    Integer into a `Context` via
#    `DateTime::from_timestamp(secs, 0).fixed_offset()` — `from_timestamp`
#    always yields a UTC `DateTime`, so `.fixed_offset()` always produces
#    offset `+00:00`, never the `-02:00` offset the epoch integer was
#    computed from (`Time.new(...).to_i` is itself offset-agnostic — the
#    offset can't be recovered from the integer). So the engine's internal
#    reference wall-clock becomes 2013-02-12T06:30:00+00:00 instead of the
#    intended 2013-02-12T04:30:00-02:00.
# 2. `time_point_to_ruby`/`time_value_to_ruby` format `TimePoint::Naive` with
#    the offset-free `"%Y-%m-%dT%H:%M:%S"` (matching this gem's documented
#    "no offset suffix" contract — see the shipped `duckling_test.rb`'s
#    `"tomorrow"`/`"at 3pm"` assertions), but format `TimePoint::Instant`
#    with `.to_rfc3339()`, which prints the (wrong) `+00:00` offset inline.
#
# Together this means every sub-day-grain relative expression below comes
# back wall-clock-shifted +2 hours from the correct value, and every
# Instant-typed result (including day-grain ones, where the +2h shift
# doesn't move the calendar date) carries a spurious "+00:00" suffix that
# violates the "no offset suffix" invariant documented for `Duckling.parse`.
# Absolute/day-level parses elsewhere in the suite ("tomorrow", "at 3pm")
# don't reveal this because they resolve to `TimePoint::Naive` and don't
# cross a day boundary sensitive to the 2-hour reference-hour error.
#
# These assertions intentionally encode the *correct* value per the wrapped
# crate's own corpus, not today's buggy output — do not loosen them to match
# the bug.
class TestDucklingParseTimeRelative < Minitest::Test
  def time_entity(text)
    results = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for #{text.inspect}, got: #{results.inspect}"
    entity
  end

  def test_in_a_minute
    entity = time_entity("in a minute")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T04:31:00", entity[:value][:value]
  end

  def test_in_2_minutes
    entity = time_entity("in 2 minutes")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T04:32:00", entity[:value][:value]
  end

  def test_2_minutes_from_now
    entity = time_entity("2 minutes from now")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T04:32:00", entity[:value][:value]
  end

  def test_in_half_an_hour
    entity = time_entity("in half an hour")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T05:00:00", entity[:value][:value]
  end

  def test_in_one_hour
    entity = time_entity("in one hour")
    assert_equal :value, entity[:value][:type]
    # Per wafer-inc-duckling's own tests/time_corpus.rs (test_time_in_one_hour),
    # "in one hour" resolves at :minute grain, not :second like the shorter
    # (sub-hour) relative durations above.
    assert_equal :minute, entity[:value][:grain]
    assert_equal "2013-02-12T05:30:00", entity[:value][:value]
  end

  def test_in_1h
    entity = time_entity("in 1h")
    assert_equal :value, entity[:value][:type]
    assert_equal :minute, entity[:value][:grain]
    assert_equal "2013-02-12T05:30:00", entity[:value][:value]
  end

  def test_7_days_ago
    entity = time_entity("7 days ago")
    assert_equal :value, entity[:value][:type]
    # Per wafer-inc-duckling's own tests/time_corpus.rs (test_time_7_days_ago),
    # a bare day-count offset ("N days ago") resolves at :hour grain, floored
    # to the reference hour (04:30 -> 04:00) rather than day grain at
    # midnight — contrast with "a week ago" below, which does floor to day.
    assert_equal :hour, entity[:value][:grain]
    assert_equal "2013-02-05T04:00:00", entity[:value][:value]
  end

  def test_a_week_ago
    entity = time_entity("a week ago")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-05T00:00:00", entity[:value][:value]
  end

  def test_in_1_week
    entity = time_entity("in 1 week")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-19T00:00:00", entity[:value][:value]
  end
end

# Extended time-interval corpus, ported from the expression groups covered in
# wafer-inc-duckling's own Rust test corpus (tests/time_corpus.rs) and the
# pyduckling test suite it descends from. Each case asserts the full
# {type: :interval, from: {...}, to: {...}} shape returned by Duckling.parse,
# not just that *an* entity was found.
class TestDucklingParseTimeInterval < Minitest::Test
  def test_hour_interval_3_4pm
    results = Duckling.parse("3-4pm", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for '3-4pm'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :hour, value[:from][:grain]
    assert_equal "2013-02-12T15:00:00", value[:from][:value]

    assert_equal :value, value[:to][:type]
    assert_equal :hour, value[:to][:grain]
    # Exclusive hour boundary: "4pm" (16:00) surfaces as 17:00, matching the
    # same convention documented in DucklingIntervalTest for "3pm to 5pm".
    assert_equal "2013-02-12T17:00:00", value[:to][:value]
  end

  def test_minute_grain_interval_3_30_to_6pm
    results = Duckling.parse("3:30 to 6 PM", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for '3:30 to 6 PM'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :minute, value[:from][:grain]
    assert_equal "2013-02-12T15:30:00", value[:from][:value]

    assert_equal :value, value[:to][:type]
    # Verified against wafer-inc-duckling's own corpus (tests/time_corpus.rs,
    # test_time_330_to_6_pm): when the interval's finer boundary ("3:30") is
    # minute-grain, the whole interval collapses to minute grain and the
    # exclusive "to" boundary is the named hour plus one *minute* (18:01),
    # not one hour (19:00) as with a pure hour-grain interval like "3-4pm".
    assert_equal :minute, value[:to][:grain]
    assert_equal "2013-02-12T18:01:00", value[:to][:value]
  end

  def test_date_range_july_13_15
    results = Duckling.parse("July 13-15", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'July 13-15'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :day, value[:from][:grain]
    assert_equal "2013-07-13T00:00:00", value[:from][:value]

    assert_equal :value, value[:to][:type]
    assert_equal :day, value[:to][:grain]
    # Exclusive end-of-range convention (mirrors the hour case): "15" surfaces
    # as the start of the 16th, not midnight of the 15th itself.
    assert_equal "2013-07-16T00:00:00", value[:to][:value]
  end

  def test_last_2_days
    results = Duckling.parse("last 2 days", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'last 2 days'"

    value = entity[:value]
    assert_equal :day, value[:from][:grain]
    assert_equal :day, value[:to][:grain]
    # Reference date is 2013-02-12; "last 2 days" should span the two days
    # immediately preceding today, i.e. [2013-02-10, 2013-02-12).
    assert_equal "2013-02-10T00:00:00", value[:from][:value]
    assert_equal "2013-02-12T00:00:00", value[:to][:value]
  end

  def test_next_3_days
    results = Duckling.parse("next 3 days", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'next 3 days'"

    value = entity[:value]
    assert_equal :day, value[:from][:grain]
    assert_equal :day, value[:to][:grain]
    # "next 3 days" spans the 3 days immediately following today, starting
    # tomorrow: [2013-02-13, 2013-02-16).
    assert_equal "2013-02-13T00:00:00", value[:from][:value]
    assert_equal "2013-02-16T00:00:00", value[:to][:value]
  end

  def test_tonight_interval
    results = Duckling.parse("tonight", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'tonight'"

    value = entity[:value]
    assert_equal :hour, value[:from][:grain]
    assert_equal "2013-02-12T18:00:00", value[:from][:value]
    assert_equal :hour, value[:to][:grain]
    assert_equal "2013-02-13T00:00:00", value[:to][:value]
  end

  def test_last_night_interval
    results = Duckling.parse("last night", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'last night'"

    value = entity[:value]
    assert_equal :hour, value[:from][:grain]
    assert_equal :hour, value[:to][:grain]
    # Reference is 2013-02-12T04:30; "last night" refers to the evening of
    # the 11th, spanning [2013-02-11T18:00, 2013-02-12T00:00).
    assert_equal "2013-02-11T18:00:00", value[:from][:value]
    assert_equal "2013-02-12T00:00:00", value[:to][:value]
  end
end

# Empirically verified (2026-07-02) against the real ext/duckling/src/lib.rs
# binding before writing any assertions below — do not trust the summary in
# this comment blindly if the Rust source changes; re-verify.
#
# `with_latent:` IS a recognized, plumbed-through keyword arg (ext/duckling/
# src/lib.rs's `get_kwargs` call lists "with_latent" among the optional
# keywords at line 43, defaults to `false` at line 50, and is threaded into
# `duckling::Options { with_latent }` at line 55 — passed straight to the
# wrapped `duckling::parse`). Passing `with_latent: true` or `with_latent:
# false` does NOT raise ArgumentError. Every observed result Hash also
# carries a `:latent` boolean key (set at lib.rs line 277-279 whenever
# `entity.latent` is `Some(_)`, which every entity observed here has).
#
# What actually flips behavior: "at 3" (a bare hour with no am/pm) — the
# case this file's spec assumed would be the classic latent example — is
# NOT gated by `with_latent` at all in practice: it comes back identically
# (one result, `latent: false`) whether `with_latent:` is omitted, false, or
# true. The construct that IS gated is a bare part-of-day term like
# "morning" or "afternoon": with `with_latent:` omitted or `false`, it
# returns `[]` (filtered out entirely); with `with_latent: true`, it returns
# one entity with `latent: true`. Unambiguous times ("3pm", "tonight")
# always come back with `latent: false` regardless of the flag.
class TestDucklingParseLatent < Minitest::Test
  def test_with_latent_kwarg_is_accepted_without_raising
    # Pins that this is a real, recognized kwarg (not a design-doc
    # assumption) — passing it in either direction must not raise.
    Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)
    Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
  end

  def test_results_carry_a_latent_boolean_field
    results = Duckling.parse("3pm", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)
    refute_empty results
    entity = results.first
    assert entity.key?(:latent), "expected result Hash to carry a :latent key"
    assert_includes [true, false], entity[:latent]
  end

  def test_with_latent_true_surfaces_part_of_day_terms_hidden_by_default
    # "morning" is the case that's actually gated: absent/false, duckling
    # withholds it entirely; true reveals it, flagged latent: true.
    without_latent_default = Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME)
    without_latent_explicit = Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
    with_latent = Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)

    assert_empty without_latent_default, "expected 'morning' to be withheld when with_latent is omitted"
    assert_empty without_latent_explicit, "expected 'morning' to be withheld when with_latent: false"

    assert_equal 1, with_latent.size, "expected 'morning' to surface exactly one entity when with_latent: true"
    entity = with_latent.first
    assert_equal "morning", entity[:body]
    assert_equal :time, entity[:dim]
    assert_equal true, entity[:latent], "expected the surfaced 'morning' entity to be flagged latent: true"
  end

  def test_bare_hour_is_not_gated_by_with_latent
    # Characterizes a surprising finding: "at 3" (bare hour, no am/pm) is the
    # textbook duckling latent-time example, but in THIS binding it is
    # returned identically regardless of with_latent — it is never withheld
    # and never flagged latent: true. So "with_latent" here specifically
    # gates part-of-day terms (see test above), not bare-hour ambiguity.
    without_kwarg = Duckling.parse("at 3", locale: "en", reference_time: REFERENCE_TIME)
    with_false = Duckling.parse("at 3", locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
    with_true = Duckling.parse("at 3", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)

    [without_kwarg, with_false, with_true].each do |results|
      assert_equal 1, results.size, "expected 'at 3' to always surface exactly one entity"
      assert_equal false, results.first[:latent], "expected 'at 3' to never be flagged latent: true"
    end

    assert_equal without_kwarg.first[:value], with_true.first[:value],
      "expected 'at 3' to resolve identically regardless of with_latent"
  end

  def test_unambiguous_times_are_never_latent_regardless_of_flag
    %w[3pm tonight].each do |text|
      with_false = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
      with_true = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME, with_latent: true)

      refute_empty with_false, "expected #{text.inspect} to parse with with_latent: false"
      refute_empty with_true, "expected #{text.inspect} to parse with with_latent: true"
      assert_equal false, with_false.first[:latent]
      assert_equal false, with_true.first[:latent]
    end
  end
end
