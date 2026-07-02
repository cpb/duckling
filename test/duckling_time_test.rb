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
