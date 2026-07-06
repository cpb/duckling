# frozen_string_literal: true

require "test_helper"
require "date"

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
end
