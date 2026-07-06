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

# Extended coverage for basic relative-time resolution, mirroring the
# wafer-inc-duckling / pyduckling en time corpus: now, today, yesterday,
# tomorrow, and this/next/last week, month, and year.
class DucklingParseTimeBasicTest < Minitest::Test
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
    assert_equal REFERENCE_TIME, entity[:value][:value]
    # "now" resolves to a TimePoint::Instant like the rest of
    # DucklingParseTimeRelativeTest below, so it needs the same explicit
    # utc_offset check — Time#== alone would not catch a regression that
    # flattens this specific code path's offset to UTC.
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_today
    entity = time_entity_for("today")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_yesterday
    entity = time_entity_for("yesterday")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 11, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_tomorrow
    entity = time_entity_for("tomorrow")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_this_week
    entity = time_entity_for("this week")
    assert_equal :value, entity[:value][:type]
    assert_equal :week, entity[:value][:grain]
    # Week containing 2013-02-12 (Tuesday) starts Monday 2013-02-11.
    assert_equal Time.new(2013, 2, 11, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_next_week
    entity = time_entity_for("next week")
    assert_equal :value, entity[:value][:type]
    assert_equal :week, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 18, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_last_week
    entity = time_entity_for("last week")
    assert_equal :value, entity[:value][:type]
    assert_equal :week, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 4, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_this_month
    entity = time_entity_for("this month")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_next_month
    entity = time_entity_for("next month")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal Time.new(2013, 3, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_last_month
    entity = time_entity_for("last month")
    assert_equal :value, entity[:value][:type]
    assert_equal :month, entity[:value][:grain]
    assert_equal Time.new(2013, 1, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_this_year
    entity = time_entity_for("this year")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal Time.new(2013, 1, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_next_year
    entity = time_entity_for("next year")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal Time.new(2014, 1, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end

  def test_last_year
    entity = time_entity_for("last year")
    assert_equal :value, entity[:value][:type]
    assert_equal :year, entity[:value][:grain]
    assert_equal Time.new(2012, 1, 1, 0, 0, 0, "-02:00"), entity[:value][:value]
  end
end
