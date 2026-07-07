# frozen_string_literal: true

require "test_helper"

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

  # Unwraps a Single-shaped entity's primary tagged TimePoint down to its
  # plain `{value:, grain:}` payload — see test_helper.rb's `time_point`.
  def single_point(entity)
    single = entity[:value][:Time][:Single]
    refute_nil single, "Expected entity[:value][:Time] to be tagged :Single, got: #{entity[:value].inspect}"
    time_point(single[:value])
  end

  def test_iso_date
    entity = first_time_entity("2015-03-03")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_short_iso_date
    entity = first_time_entity("2015-3-3")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_us_slash_date_full_year
    entity = first_time_entity("3/3/2015")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_us_slash_date_two_digit_year
    entity = first_time_entity("3/3/15")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_month_name_date_with_explicit_year
    entity = first_time_entity("march 3 2015")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2015, 3, 3, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_month_name_date_implied_current_year
    entity = first_time_entity("march 3")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    # No year specified — should resolve against REFERENCE_TIME's year (2013).
    assert_equal Time.new(2013, 3, 3, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_day_of_month_month_then_day
    entity = first_time_entity("february 15")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 15, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_day_of_month_ordinal_of_month
    entity = first_time_entity("the 15th of february")
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 15, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_numeric_month_slash_year
    entity = first_time_entity("2/2013")
    point = single_point(entity)
    assert_equal :month, point[:grain]
    assert_equal Time.new(2013, 2, 1, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_month_name_and_year
    entity = first_time_entity("October 2014")
    point = single_point(entity)
    assert_equal :month, point[:grain]
    assert_equal Time.new(2014, 10, 1, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_year_only
    entity = first_time_entity("in 2014")
    point = single_point(entity)
    assert_equal :year, point[:grain]
    assert_equal Time.new(2014, 1, 1, 0, 0, 0, "-02:00"), point[:value]
  end
end
