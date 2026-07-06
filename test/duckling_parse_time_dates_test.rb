# frozen_string_literal: true

require "test_helper"

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00, a Tuesday), so relative expressions
# resolve to fixed, assertable values instead of drifting with the real clock.
# See test/duckling_test.rb for the same convention. Guarded with `unless
# defined?` since this file may load in the same process as duckling_test.rb
# (which defines the same top-level constant) via `bundle exec rake test`, or
# standalone via `bin/test test/duckling_time_test.rb`. A real `Time` (not an
# Integer): `Native.parse`'s `reference_time:` requires a `Time`-like value
# (or something responding to `#to_time`) so its `utc_offset` can be threaded
# through to `Naive` results via `Context::timezone()` — an Integer can't
# carry an offset at all.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00") unless defined?(REFERENCE_TIME)

# Extended corpus for absolute date expressions, ported in spirit from the
# Ruby/Haskell/Rust duckling test suites' `TimeCorpus` date coverage: ISO
# dates, short ISO dates, US-style slash dates, month-name dates (with and
# without an explicit year), day-of-month expressions, and month/year-only
# forms. Matches the reference time used throughout the rest of this gem's
# test suite (2013-02-12T04:30:00-02:00), so relative/implied-year
# expressions resolve to fixed, assertable values.
class DucklingParseTimeDatesTest < Minitest::Test
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
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_short_iso_date
    entity = first_time_entity("2015-3-3")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_us_slash_date_full_year
    entity = first_time_entity("3/3/2015")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_us_slash_date_two_digit_year
    entity = first_time_entity("3/3/15")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_month_name_date_with_explicit_year
    entity = first_time_entity("march 3 2015")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_month_name_date_implied_current_year
    entity = first_time_entity("march 3")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    # No year specified — should resolve against REFERENCE_TIME's year (2013).
    assert_equal Time.new(2013, 3, 3, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_day_of_month_month_then_day
    entity = first_time_entity("february 15")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 15, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_day_of_month_ordinal_of_month
    entity = first_time_entity("the 15th of february")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 15, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_numeric_month_slash_year
    entity = first_time_entity("2/2013")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_month_name_and_year
    entity = first_time_entity("October 2014")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal Time.new(2014, 10, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_year_only
    entity = first_time_entity("in 2014")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal Time.new(2014, 1, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end
end
