# frozen_string_literal: true

require "test_helper"

# Extended time-interval corpus, ported from the expression groups covered in
# wafer-inc-duckling's own Rust test corpus (tests/time_corpus.rs) and the
# pyduckling test suite it descends from. Each case asserts the full
# {type: :interval, from: {...}, to: {...}} shape returned by Duckling.parse,
# not just that *an* entity was found.
class DucklingParseTimeIntervalTest < Minitest::Test
  def test_hour_interval_3_4pm
    results = Duckling.parse("3-4pm", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for '3-4pm'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :hour, value[:from][:grain]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), value[:from][:value]

    assert_equal :value, value[:to][:type]
    assert_equal :hour, value[:to][:grain]
    # Exclusive hour boundary: "4pm" (16:00) surfaces as 17:00, matching the
    # same convention documented in DucklingIntervalTest for "3pm to 5pm".
    assert_equal Time.new(2013, 2, 12, 17, 0, 0, "-02:00"), value[:to][:value]
  end

  def test_minute_grain_interval_3_30_to_6pm
    results = Duckling.parse("3:30 to 6 PM", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for '3:30 to 6 PM'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :minute, value[:from][:grain]
    assert_equal Time.new(2013, 2, 12, 15, 30, 0, "-02:00"), value[:from][:value]

    assert_equal :value, value[:to][:type]
    # Verified against wafer-inc-duckling's own corpus (tests/time_corpus.rs,
    # test_time_330_to_6_pm): when the interval's finer boundary ("3:30") is
    # minute-grain, the whole interval collapses to minute grain and the
    # exclusive "to" boundary is the named hour plus one *minute* (18:01),
    # not one hour (19:00) as with a pure hour-grain interval like "3-4pm".
    assert_equal :minute, value[:to][:grain]
    assert_equal Time.new(2013, 2, 12, 18, 1, 0, "-02:00"), value[:to][:value]
  end

  def test_date_range_july_13_15
    results = Duckling.parse("July 13-15", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'July 13-15'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :day, value[:from][:grain]
    assert_equal Time.new(2013, 7, 13, 0, 0, 0, "-02:00"), value[:from][:value]

    assert_equal :value, value[:to][:type]
    assert_equal :day, value[:to][:grain]
    # Exclusive end-of-range convention (mirrors the hour case): "15" surfaces
    # as the start of the 16th, not midnight of the 15th itself.
    assert_equal Time.new(2013, 7, 16, 0, 0, 0, "-02:00"), value[:to][:value]
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
    assert_equal Time.new(2013, 2, 10, 0, 0, 0, "-02:00"), value[:from][:value]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), value[:to][:value]
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
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), value[:from][:value]
    assert_equal Time.new(2013, 2, 16, 0, 0, 0, "-02:00"), value[:to][:value]
  end

  def test_tonight_interval
    results = Duckling.parse("tonight", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'tonight'"

    value = entity[:value]
    assert_equal :hour, value[:from][:grain]
    assert_equal Time.new(2013, 2, 12, 18, 0, 0, "-02:00"), value[:from][:value]
    assert_equal :hour, value[:to][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), value[:to][:value]
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
    assert_equal Time.new(2013, 2, 11, 18, 0, 0, "-02:00"), value[:from][:value]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), value[:to][:value]
  end
end
