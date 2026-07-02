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
# KNOWN BUG, confirmed by reading this gem's own binding source (not
# guessed): every test below whose expression resolves to a
# `TimePoint::Instant` (i.e. everything in this file — relative
# second/minute/hour/day offsets from "now") fails today, in two ways:
#
# 1. `ext/duckling/src/lib.rs`'s `build_context` turns the `reference_time:`
#    Integer into a `Context` via
#    `DateTime::from_timestamp(secs, 0).fixed_offset()` — `from_timestamp`
#    always yields a UTC `DateTime`, so `.fixed_offset()` always produces
#    offset `+00:00`, never the `-02:00` offset the epoch integer was
#    computed from (`Time.new(...).to_i` is itself offset-agnostic — the
#    offset can't be recovered from the integer). So the engine's internal
#    reference wall-clock becomes 2013-02-12T06:30:00+00:00 instead of the
#    intended 2013-02-12T04:30:00-02:00.
# 2. `time_point_to_ruby`/`time_value_to_ruby` format `TimePoint::Naive` with
#    the offset-free `"%Y-%m-%dT%H:%M:%S"` (matching this gem's documented
#    "no offset suffix" contract — see the shipped `duckling_test.rb`'s
#    `"tomorrow"`/`"at 3pm"` assertions), but format `TimePoint::Instant`
#    with `.to_rfc3339()`, which prints the (wrong) `+00:00` offset inline.
#
# Together this means every sub-day-grain relative expression below comes
# back wall-clock-shifted +2 hours from the correct value, and every
# Instant-typed result (including day-grain ones, where the +2h shift
# doesn't move the calendar date) carries a spurious "+00:00" suffix that
# violates the "no offset suffix" invariant documented for `Duckling.parse`.
# Absolute/day-level parses elsewhere in the suite ("tomorrow", "at 3pm")
# don't reveal this because they resolve to `TimePoint::Naive` and don't
# cross a day boundary sensitive to the 2-hour reference-hour error.
#
# These assertions intentionally encode the *correct* value per the wrapped
# crate's own corpus, not today's buggy output — do not loosen them to match
# the bug.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i

class TestDucklingParseTimeRelative < Minitest::Test
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
    assert_equal "2013-02-12T04:31:00", entity[:value][:value]
  end

  def test_in_2_minutes
    entity = time_entity("in 2 minutes")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T04:32:00", entity[:value][:value]
  end

  def test_2_minutes_from_now
    entity = time_entity("2 minutes from now")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T04:32:00", entity[:value][:value]
  end

  def test_in_half_an_hour
    entity = time_entity("in half an hour")
    assert_equal :value, entity[:value][:type]
    assert_equal :second, entity[:value][:grain]
    assert_equal "2013-02-12T05:00:00", entity[:value][:value]
  end

  def test_in_one_hour
    entity = time_entity("in one hour")
    assert_equal :value, entity[:value][:type]
    # Per wafer-inc-duckling's own tests/time_corpus.rs (test_time_in_one_hour),
    # "in one hour" resolves at :minute grain, not :second like the shorter
    # (sub-hour) relative durations above.
    assert_equal :minute, entity[:value][:grain]
    assert_equal "2013-02-12T05:30:00", entity[:value][:value]
  end

  def test_in_1h
    entity = time_entity("in 1h")
    assert_equal :value, entity[:value][:type]
    assert_equal :minute, entity[:value][:grain]
    assert_equal "2013-02-12T05:30:00", entity[:value][:value]
  end

  def test_7_days_ago
    entity = time_entity("7 days ago")
    assert_equal :value, entity[:value][:type]
    # Per wafer-inc-duckling's own tests/time_corpus.rs (test_time_7_days_ago),
    # a bare day-count offset ("N days ago") resolves at :hour grain, floored
    # to the reference hour (04:30 -> 04:00) rather than day grain at
    # midnight — contrast with "a week ago" below, which does floor to day.
    assert_equal :hour, entity[:value][:grain]
    assert_equal "2013-02-05T04:00:00", entity[:value][:value]
  end

  def test_a_week_ago
    entity = time_entity("a week ago")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-05T00:00:00", entity[:value][:value]
  end

  def test_in_1_week
    entity = time_entity("in 1 week")
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal "2013-02-19T00:00:00", entity[:value][:value]
  end
end
