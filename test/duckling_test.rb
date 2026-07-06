# frozen_string_literal: true

require "test_helper"
require "date"
require "tzinfo"

VALID_GRAINS = %i[second minute hour day week month quarter year].freeze

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00), so relative expressions resolve to fixed,
# assertable values instead of drifting with the real clock.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")

class DucklingTest < Minitest::Test
  def test_parse_returns_array
    assert_kind_of Array, Duckling.parse("tomorrow", locale: "en")
  end

  def test_parse_result_shape
    results = Duckling.parse("at 3pm", locale: "en", reference_time: REFERENCE_TIME)
    assert results.size > 0, "Expected at least one result from Duckling.parse"
    first = results.first
    assert first.key?(:body), "Expected result to have :body key"
    assert first.key?(:start), "Expected result to have :start key"
    assert first.key?(:end), "Expected result to have :end key"
    assert first.key?(:dim), "Expected result to have :dim key"
    assert first.key?(:value), "Expected result to have :value key"
    value = first[:value]
    assert_kind_of Hash, value, "Expected :value to be a Hash"
    assert value.key?(:type), "Expected :value to have :type key"
    assert value.key?(:value), "Expected :value to have :value key"
    assert value.key?(:grain), "Expected :value to have :grain key"
    assert_equal "at 3pm", first[:body]
    assert_equal :value, value[:type]
    assert_equal :hour, value[:grain]
    assert_kind_of Time, value[:value]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), value[:value]
  end

  def test_parses_time_dimension
    results = Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow'"
    assert_includes VALID_GRAINS, time_entity[:value][:grain],
      "Expected grain to be one of #{VALID_GRAINS.inspect}"
    assert_equal :day, time_entity[:value][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), time_entity[:value][:value]
  end

  def test_parity_with_wafer_inc_duckling
    results = Duckling.parse("Call me tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    assert_operator results.size, :>=, 1, "expected at least one entity for 'Call me tomorrow'"
    entity = results.find { |r| r[:body] == "tomorrow" }
    refute_nil entity, "expected an entity with body: 'tomorrow'"
    assert_equal :time, entity[:dim]
    assert_equal :value, entity[:value][:type]
    assert_equal :day, entity[:value][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), entity[:value][:value]
    assert_kind_of Array, entity[:value][:values]
    assert entity[:value][:values].size > 0, "expected :values to be a non-empty Array"
  end

  def test_parses_interval
    results = Duckling.parse("from 3pm to 5pm", locale: "en", reference_time: REFERENCE_TIME)
    assert results.size > 0
    entity = results.first
    assert_equal :time, entity[:dim]
    assert_equal :interval, entity[:value][:type]
    assert entity[:value].key?(:from), "interval value should have :from"
    assert entity[:value].key?(:to), "interval value should have :to"
    assert_equal :value, entity[:value][:from][:type]
    assert_equal :hour, entity[:value][:from][:grain]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), entity[:value][:from][:value]
    assert_equal :value, entity[:value][:to][:type]
    assert_equal :hour, entity[:value][:to][:grain]
    # duckling represents interval :to as the exclusive hour boundary, not the
    # literal named time — "5pm" (17:00) surfaces as 18:00. Verified against
    # wafer-inc-duckling's own tests/time_corpus.rs (e.g. "3-4pm" -> to 17:00).
    assert_equal Time.new(2013, 2, 12, 18, 0, 0, "-02:00"), entity[:value][:to][:value]
  end

  def test_time_reference_time_preserves_utc_offset_for_instant_results
    results = Duckling.parse("in one hour", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'in one hour'"
    assert_kind_of Time, entity[:value][:value]
    assert_equal REFERENCE_TIME + 3600, entity[:value][:value]
    # Time#== only compares the instant, not utc_offset — assert this
    # explicitly since preserving the offset is the whole point of this test.
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_non_time_reference_time_raises_type_error
    assert_raises(TypeError) do
      Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME.to_i)
    end
  end

  def test_date_time_reference_time_is_coerced_and_preserves_utc_offset
    reference_time = DateTime.new(2013, 2, 12, 4, 30, 0, "-02:00")
    results = Duckling.parse("in one hour", locale: "en", reference_time: reference_time)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'in one hour'"
    assert_kind_of Time, entity[:value][:value]
    assert_equal REFERENCE_TIME + 3600, entity[:value][:value]
    assert_equal(-7200, entity[:value][:value].utc_offset)
  end

  def test_naive_result_after_dst_transition_gets_post_transition_offset
    reference_time = Time.new(2013, 1, 15, 4, 30, 0, "-05:00") # EST
    results = Duckling.parse("june 15", locale: "en",
      reference_time: reference_time, reference_zone: "America/New_York")
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'june 15'"
    assert_kind_of Time, entity[:value][:value]
    # America/New_York is on EDT (-04:00) by June 15 2013 (2013 DST ran
    # March 10 - November 3), not the reference's own EST (-05:00) offset --
    # applying the real zone's per-date offset is the whole point of
    # reference_zone:.
    assert_equal Time.new(2013, 6, 15, 0, 0, 0, "-04:00"), entity[:value][:value]
    assert_equal(-4 * 3600, entity[:value][:value].utc_offset)
  end

  def test_omitting_reference_zone_keeps_single_fixed_offset_behavior
    reference_time = Time.new(2013, 1, 15, 4, 30, 0, "-05:00") # EST
    results = Duckling.parse("june 15", locale: "en", reference_time: reference_time)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'june 15'"
    assert_kind_of Time, entity[:value][:value]
    # Without reference_zone:, today's behavior applies reference_time's own
    # fixed offset uniformly, even though America/New_York (the zone this
    # reference_time happens to represent) is really on EDT (-04:00) by
    # June 15 -- this pins that unchanged default so the reference_zone:
    # feature can never become accidentally mandatory.
    assert_equal Time.new(2013, 6, 15, 0, 0, 0, "-05:00"), entity[:value][:value]
    assert_equal(-5 * 3600, entity[:value][:value].utc_offset)
  end

  def test_reference_zone_without_reference_time_anchors_at_current_time_in_zone
    # Stubbing Ruby's Time.now would not affect this at all: when
    # reference_time: is omitted, Native.parse's default Context comes from
    # Rust's own chrono::Utc::now() (ext/duckling crate's resolve.rs), which
    # never calls back into Ruby. So instead of faking "now", assert against
    # a real ground-truth oracle (tzinfo) for whatever instant the suite
    # actually runs at -- this holds regardless of *how* an implementation
    # sources "now" (Ruby-side Time.now, Rust-side Utc::now(), etc.), since
    # it only pins the observable contract: the resolved offset/date must
    # match the zone's real current offset/date, not reference_time:'s.
    zone = TZInfo::Timezone.get("America/New_York")
    utc_now = Time.now.utc
    expected_offset = zone.period_for(utc_now).utc_total_offset
    expected_date = zone.to_local(utc_now).to_date

    results = Duckling.parse("today", locale: "en", reference_zone: "America/New_York")
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'today'"
    assert_kind_of Time, entity[:value][:value]
    assert_equal expected_date, entity[:value][:value].to_date
    assert_equal expected_offset, entity[:value][:value].utc_offset
  end

  def test_reference_time_utc_offset_disagreeing_with_zone_raises_argument_error
    reference_time = Time.new(2013, 6, 15, 12, 0, 0, "+00:00") # UTC, disagrees with EDT -04:00
    error = assert_raises(ArgumentError) do
      Duckling.parse("tomorrow", locale: "en",
        reference_time: reference_time, reference_zone: "America/New_York")
    end
    assert_match(/utc_offset/i, error.message,
      "expected a mismatch error mentioning utc_offset, got: #{error.message.inspect}")
  end

  def test_naive_result_landing_in_a_dst_spring_forward_gap_raises_argument_error
    # 2013-03-10 02:30 America/New_York never occurs -- clocks jump from
    # 01:59:59 EST straight to 03:00:00 EDT. A naive result that resolves to
    # this wall-clock value must surface as the gem's own ArgumentError
    # contract for bad input, not an implementation-specific exception.
    error = assert_raises(ArgumentError) do
      Duckling.parse("march 10 2013 at 2:30am", locale: "en", reference_zone: "America/New_York")
    end
    assert_match(/invalid or ambiguous naive time/i, error.message,
      "expected the naive-time-resolution contract's own message, got: #{error.message.inspect}")
  end

  def test_naive_result_landing_in_a_dst_fall_back_ambiguous_time_raises_argument_error
    # 2013-11-03 01:30 America/New_York occurs twice -- once at EDT, once at
    # EST -- as clocks fall back. Same ArgumentError contract applies.
    error = assert_raises(ArgumentError) do
      Duckling.parse("november 3 2013 at 1:30am", locale: "en", reference_zone: "America/New_York")
    end
    assert_match(/invalid or ambiguous naive time/i, error.message,
      "expected the naive-time-resolution contract's own message, got: #{error.message.inspect}")
  end
end
