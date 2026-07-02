# frozen_string_literal: true

require "test_helper"

# Extended corpus for absolute date expressions, ported in spirit from the
# Ruby/Haskell/Rust duckling test suites' `TimeCorpus` date coverage: ISO
# dates, short ISO dates, US-style slash dates, month-name dates (with and
# without an explicit year), day-of-month expressions, and month/year-only
# forms. Matches the reference time used throughout the rest of this gem's
# test suite (2013-02-12T04:30:00-02:00), so relative/implied-year
# expressions resolve to fixed, assertable values.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i

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
