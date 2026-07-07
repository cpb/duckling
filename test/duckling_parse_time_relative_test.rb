# frozen_string_literal: true

require "test_helper"

# Extended corpus of relative-time expressions, ported from the intent of the
# Ruby test design doc for issue #34. Reference time matches the rest of the
# suite (2013-02-12T04:30:00-02:00) so relative expressions resolve to fixed,
# assertable values. Expected :value/:grain pairs below are taken directly
# from the wrapped Rust crate's own ground-truth corpus
# (~/.cargo/registry/src/*/duckling-0.4.0/tests/time_corpus.rs, e.g.
# `test_time_in_a_minute`, `test_time_in_one_hour`, `test_time_7_days_ago`,
# `test_time_a_week_ago`, `test_time_in_1_week`), not guessed.
#
# Every expression below resolves to a `TimePoint::Instant`, so this is the
# class that actually exercises `reference_time:`'s offset propagation into
# `Context::timezone()` (see ext/duckling/src/lib.rs's `entity_to_ruby` and
# friends) — each test below asserts `.utc_offset` explicitly in addition to
# the resolved `Time`, since `Time#==` only compares the instant.
class DucklingParseTimeRelativeTest < Minitest::Test
  def test_in_a_minute
    entity = entity_for("in a minute", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 60, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_2_minutes
    entity = entity_for("in 2 minutes", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 120, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_2_minutes_from_now
    entity = entity_for("2 minutes from now", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 120, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_half_an_hour
    entity = entity_for("in half an hour", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 1800, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_one_hour
    entity = entity_for("in one hour", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    # Per wafer-inc-duckling's own tests/time_corpus.rs (test_time_in_one_hour),
    # "in one hour" resolves at :minute grain, not :second like the shorter
    # (sub-hour) relative durations above.
    assert_equal :minute, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 3600, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_1h
    entity = entity_for("in 1h", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    assert_equal :minute, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 3600, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_7_days_ago
    entity = entity_for("7 days ago", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    # Per wafer-inc-duckling's own tests/time_corpus.rs (test_time_7_days_ago),
    # a bare day-count offset ("N days ago") resolves at :hour grain, floored
    # to the reference hour (04:30 -> 04:00) rather than day grain at
    # midnight — contrast with "a week ago" below, which does floor to day.
    assert_equal :hour, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 5, 4, 0, 0, "-02:00"), entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_a_week_ago
    entity = entity_for("a week ago", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 5, 0, 0, 0, "-02:00"), entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_1_week
    entity = entity_for("in 1 week", :time, reference_time: REFERENCE_TIME)
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 19, 0, 0, 0, "-02:00"), entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  # Issue #91: migrate :time onto the unified serde_magnus tagged shape
  # established for the other 13 dimensions in #90. "christmas" is the
  # representative case for two pieces of Time-specific behavior that shape
  # migration must preserve and correctly re-tag:
  #
  # 1. Holiday recognition: duckling resolves "christmas" with
  #    `holiday: Some("Christmas")` on the Rust side. Under #90's convention,
  #    `Option::Some` fields keep their serde `rename`d key (`holidayBeta`)
  #    symbolized, holding the plain String unchanged — unlike `quantity`'s
  #    `product:`, which #90 documented as an *explicit* nil key when absent;
  #    `holiday`'s `skip_serializing_if` means it must be entirely ABSENT
  #    (not nil) when not present, though that absent case isn't covered here.
  # 2. Recurrence: duckling returns up to 3 upcoming occurrences in `values`
  #    (including the primary as element 0). Each element of that array must
  #    be individually tagged the same way the top-level `value` is
  #    (`{Naive: {value:, grain:}}` / `{Instant: {value:, grain:}}`) — the
  #    tagging convention applies uniformly to every nested `TimePoint`, not
  #    just the top-level one.
  def test_christmas_holiday_and_recurrence
    entity = entity_for("christmas", :time, reference_time: REFERENCE_TIME)

    single = entity[:value][:Time][:Single]

    assert_equal "Christmas", single[:holidayBeta]

    primary = single[:value][:Naive]
    refute_nil primary, "Expected the primary time point to be tagged :Naive, got: #{single[:value].inspect}"
    assert_kind_of Time, primary[:value]
    assert_equal 2013, primary[:value].year
    assert_equal 12, primary[:value].month
    assert_equal 25, primary[:value].day

    assert_kind_of Array, single[:values]
    refute_empty single[:values]
    assert single[:values].first.key?(:Naive),
      "Expected each recurrence entry to be individually tagged (e.g. :Naive), got: #{single[:values].first.inspect}"
  end
end
