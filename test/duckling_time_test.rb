# frozen_string_literal: true

require "test_helper"

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00, a Tuesday), so relative expressions
# resolve to fixed, assertable values instead of drifting with the real clock.
# See test/duckling_test.rb for the same convention.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i

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
