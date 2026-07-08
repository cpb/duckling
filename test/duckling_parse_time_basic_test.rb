# frozen_string_literal: true

require "test_helper"

# Extended coverage for basic relative-time resolution, mirroring the
# wafer-inc-duckling / pyduckling en time corpus: now, today, yesterday,
# tomorrow, and this/next/last week, month, and year.
class DucklingParseTimeBasicTest < Minitest::Test
  def test_now
    entity = entity_for("now", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :second, point[:grain]
    assert_equal REFERENCE_TIME, point[:value]
    # "now" resolves to a TimePoint::Instant like the rest of
    # DucklingParseTimeRelativeTest below, so it needs the same explicit
    # utc_offset check — Time#== alone would not catch a regression that
    # flattens this specific code path's offset to UTC.
    assert_equal(-7200, point[:value].utc_offset)
  end

  # Pins the post-#90 tagged shape for :time's Single/Instant case (issue #91).
  # The critical assertion is the explicit `is_a?(Time)` check on the datetime
  # leaf: a generic serde_magnus serialization of DateTime<FixedOffset> would
  # produce a plain Ruby String there, and a bare `assert_equal` against a
  # Time literal would NOT catch that regression (String#== against a
  # stringified Time could coincidentally match), so this test must assert
  # the type explicitly rather than relying on equality alone.
  def test_now_value_is_tagged_instant_shape_with_real_time
    entity = entity_for("now", :time, reference_time: REFERENCE_TIME)
    single = entity[:value][:Time][:Single]

    instant_value = single[:value][:Instant][:value]
    assert_kind_of Time, instant_value, "Expected the Instant leaf's :value to be a real Ruby Time, not a serialized String"
    assert_equal REFERENCE_TIME, instant_value
    assert_equal(-7200, instant_value.utc_offset)

    assert_equal :second, single[:value][:Instant][:grain]

    refute_empty single[:values]
    first_value = single[:values].first[:Instant][:value]
    assert_kind_of Time, first_value
  end

  def test_today
    entity = entity_for("today", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_yesterday
    entity = entity_for("yesterday", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 11, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_tomorrow
    entity = entity_for("tomorrow", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_tomorrow_tagged_naive_shape
    entity = entity_for("tomorrow", :time, reference_time: REFERENCE_TIME)
    naive = entity[:value][:Time][:Single][:value][:Naive]
    assert_kind_of Time, naive[:value],
      "Expected entity[:value][:Time][:Single][:value][:Naive][:value] to be a real Ruby Time"
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), naive[:value]
    assert_equal :day, naive[:grain]
    values = entity[:value][:Time][:Single][:values]
    assert_kind_of Array, values
    refute_empty values
  end

  def test_this_week
    entity = entity_for("this week", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :week, point[:grain]
    # Week containing 2013-02-12 (Tuesday) starts Monday 2013-02-11.
    assert_equal Time.new(2013, 2, 11, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_next_week
    entity = entity_for("next week", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :week, point[:grain]
    assert_equal Time.new(2013, 2, 18, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_last_week
    entity = entity_for("last week", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :week, point[:grain]
    assert_equal Time.new(2013, 2, 4, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_this_month
    entity = entity_for("this month", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :month, point[:grain]
    assert_equal Time.new(2013, 2, 1, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_next_month
    entity = entity_for("next month", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :month, point[:grain]
    assert_equal Time.new(2013, 3, 1, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_last_month
    entity = entity_for("last month", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :month, point[:grain]
    assert_equal Time.new(2013, 1, 1, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_this_year
    entity = entity_for("this year", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :year, point[:grain]
    assert_equal Time.new(2013, 1, 1, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_next_year
    entity = entity_for("next year", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :year, point[:grain]
    assert_equal Time.new(2014, 1, 1, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_last_year
    entity = entity_for("last year", :time, reference_time: REFERENCE_TIME)
    point = single_point(entity)
    assert_equal :year, point[:grain]
    assert_equal Time.new(2012, 1, 1, 0, 0, 0, "-02:00"), point[:value]
  end
end
