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
  def time_entity(text)
    results = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for #{text.inspect}, got: #{results.inspect}"
    entity
  end

  def test_in_a_minute
    entity = time_entity("in a minute")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 60, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_2_minutes
    entity = time_entity("in 2 minutes")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 120, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_2_minutes_from_now
    entity = time_entity("2 minutes from now")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 120, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_half_an_hour
    entity = time_entity("in half an hour")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 1800, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_one_hour
    entity = time_entity("in one hour")
    assert_equal :value, entity[:value][:type]
    # Per wafer-inc-duckling's own tests/time_corpus.rs (test_time_in_one_hour),
    # "in one hour" resolves at :minute grain, not :second like the shorter
    # (sub-hour) relative durations above.
    assert_equal :minute, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 3600, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_1h
    entity = time_entity("in 1h")
    assert_equal :value, entity[:value][:type]
    assert_equal :minute, entity[:value][:grain]
    assert_equal REFERENCE_TIME + 3600, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_7_days_ago
    entity = time_entity("7 days ago")
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
    entity = time_entity("a week ago")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 5, 0, 0, 0, "-02:00"), entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_in_1_week
    entity = time_entity("in 1 week")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 19, 0, 0, 0, "-02:00"), entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end
end
