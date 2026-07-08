# frozen_string_literal: true

require "test_helper"

# Extended time-interval corpus, ported from the expression groups covered in
# wafer-inc-duckling's own Rust test corpus (tests/time_corpus.rs) and the
# pyduckling test suite it descends from. Each case asserts the full
# {Time: {Interval: {from: {...}, to: {...}}}} shape returned by
# Duckling.parse (issue #91's unified externally-tagged convention), not just
# that *an* entity was found.
class DucklingParseTimeIntervalTest < Minitest::Test
  def test_hour_interval_3_4pm
    entity = entity_for("3-4pm", :time, reference_time: REFERENCE_TIME)
    from, to = interval_points(entity)

    assert_equal :hour, from[:grain]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), from[:value]

    assert_equal :hour, to[:grain]
    # Exclusive hour boundary: "4pm" (16:00) surfaces as 17:00, matching the
    # same convention documented in DucklingIntervalTest for "3pm to 5pm".
    assert_equal Time.new(2013, 2, 12, 17, 0, 0, "-02:00"), to[:value]
  end

  def test_minute_grain_interval_3_30_to_6pm
    entity = entity_for("3:30 to 6 PM", :time, reference_time: REFERENCE_TIME)
    from, to = interval_points(entity)

    assert_equal :minute, from[:grain]
    assert_equal Time.new(2013, 2, 12, 15, 30, 0, "-02:00"), from[:value]

    # Verified against wafer-inc-duckling's own corpus (tests/time_corpus.rs,
    # test_time_330_to_6_pm): when the interval's finer boundary ("3:30") is
    # minute-grain, the whole interval collapses to minute grain and the
    # exclusive "to" boundary is the named hour plus one *minute* (18:01),
    # not one hour (19:00) as with a pure hour-grain interval like "3-4pm".
    assert_equal :minute, to[:grain]
    assert_equal Time.new(2013, 2, 12, 18, 1, 0, "-02:00"), to[:value]
  end

  def test_date_range_july_13_15
    entity = entity_for("July 13-15", :time, reference_time: REFERENCE_TIME)
    from, to = interval_points(entity)

    assert_equal :day, from[:grain]
    assert_equal Time.new(2013, 7, 13, 0, 0, 0, "-02:00"), from[:value]

    assert_equal :day, to[:grain]
    # Exclusive end-of-range convention (mirrors the hour case): "15" surfaces
    # as the start of the 16th, not midnight of the 15th itself.
    assert_equal Time.new(2013, 7, 16, 0, 0, 0, "-02:00"), to[:value]
  end

  def test_last_2_days
    entity = entity_for("last 2 days", :time, reference_time: REFERENCE_TIME)
    from, to = interval_points(entity)

    assert_equal :day, from[:grain]
    assert_equal :day, to[:grain]
    # Reference date is 2013-02-12; "last 2 days" should span the two days
    # immediately preceding today, i.e. [2013-02-10, 2013-02-12).
    assert_equal Time.new(2013, 2, 10, 0, 0, 0, "-02:00"), from[:value]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), to[:value]
  end

  def test_next_3_days
    entity = entity_for("next 3 days", :time, reference_time: REFERENCE_TIME)
    from, to = interval_points(entity)

    assert_equal :day, from[:grain]
    assert_equal :day, to[:grain]
    # "next 3 days" spans the 3 days immediately following today, starting
    # tomorrow: [2013-02-13, 2013-02-16).
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), from[:value]
    assert_equal Time.new(2013, 2, 16, 0, 0, 0, "-02:00"), to[:value]
  end

  def test_tonight_interval
    entity = entity_for("tonight", :time, reference_time: REFERENCE_TIME)
    from, to = interval_points(entity)

    assert_equal :hour, from[:grain]
    assert_equal Time.new(2013, 2, 12, 18, 0, 0, "-02:00"), from[:value]
    assert_equal :hour, to[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), to[:value]
  end

  def test_interval_tagged_shape_3pm_to_5pm
    entity = entity_for("from 3pm to 5pm", :time, reference_time: REFERENCE_TIME)

    value = entity[:value]
    assert value.key?(:Time), "expected value to be tagged with :Time, got: #{value.inspect}"
    time_value = value[:Time]
    assert time_value.key?(:Interval), "expected :Time value to be tagged :Interval, got: #{time_value.inspect}"
    refute time_value.key?(:Single), "expected :Time value NOT to be tagged :Single for an interval expression"

    interval = time_value[:Interval]

    from_point = interval[:from][:Naive]
    assert_kind_of Time, from_point[:value], "expected :from value to be a real Ruby Time, got: #{from_point[:value].inspect}"
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), from_point[:value]
    assert_equal :hour, from_point[:grain]

    to_point = interval[:to][:Naive]
    assert_kind_of Time, to_point[:value], "expected :to value to be a real Ruby Time, got: #{to_point[:value].inspect}"
    assert_equal Time.new(2013, 2, 12, 18, 0, 0, "-02:00"), to_point[:value]
    assert_equal :hour, to_point[:grain]
  end

  # patch_time_value (ext/duckling/src/lib.rs) walks Interval's `values`
  # recurrence array and patches each entry's `from`/`to` individually, the
  # same way it patches the top-level `from`/`to` above — pin that here so a
  # regression in that walk (entries silently reverting to serde's raw
  # RFC3339-String/PascalCase-grain placeholders) fails a test instead of
  # shipping unnoticed.
  def test_interval_recurrence_values_are_individually_tagged
    entity = entity_for("from 3pm to 5pm", :time, reference_time: REFERENCE_TIME)
    interval = entity[:value][:Time][:Interval]

    values = interval[:values]
    assert_kind_of Array, values
    refute_empty values

    first = values.first
    from_point = time_point(first[:from])
    assert_kind_of Time, from_point[:value], "expected values.first[:from] to be a real Ruby Time, got: #{from_point[:value].inspect}"
    assert_equal :hour, from_point[:grain]

    to_point = time_point(first[:to])
    assert_kind_of Time, to_point[:value], "expected values.first[:to] to be a real Ruby Time, got: #{to_point[:value].inspect}"
    assert_equal :hour, to_point[:grain]
  end

  # Companion to the recurrence-values test above: pins the current
  # unbounded-endpoint contract (issue #91) — TimeValue::Interval's `from`/`to`
  # fields have no `skip_serializing_if`, so the generic serialize-then-patch
  # path always emits the key, `nil` when the interval is unbounded, unlike
  # the pre-#91 flattened shape which omitted the key entirely in this case.
  def test_unbounded_interval_after_3pm_has_explicit_nil_to
    entity = entity_for("after 3pm", :time, reference_time: REFERENCE_TIME)
    interval = entity[:value][:Time][:Interval]

    assert interval.key?(:from), "expected :from to be a real bound"
    from_point = time_point(interval[:from])
    assert_kind_of Time, from_point[:value]

    assert interval.key?(:to), "expected :to key to be present (even if nil) for an unbounded interval"
    assert_nil interval[:to], "expected :to to be explicitly nil for an unbounded interval, got: #{interval[:to].inspect}"
  end

  def test_last_night_interval
    entity = entity_for("last night", :time, reference_time: REFERENCE_TIME)
    from, to = interval_points(entity)

    assert_equal :hour, from[:grain]
    assert_equal :hour, to[:grain]
    # Reference is 2013-02-12T04:30; "last night" refers to the evening of
    # the 11th, spanning [2013-02-11T18:00, 2013-02-12T00:00).
    assert_equal Time.new(2013, 2, 11, 18, 0, 0, "-02:00"), from[:value]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), to[:value]
  end
end
