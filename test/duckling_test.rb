# frozen_string_literal: true

require "test_helper"
require "date"

VALID_GRAINS = %i[second minute hour day week month quarter year].freeze

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
    assert value.key?(:Time), "Expected :value to be tagged :Time"
    single = value[:Time][:Single]
    refute_nil single, "Expected :value to be tagged :Single, got: #{value.inspect}"
    point = time_point(single[:value])
    assert_equal "at 3pm", first[:body]
    assert_equal :hour, point[:grain]
    assert_kind_of Time, point[:value]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), point[:value]
  end

  def test_parses_time_dimension
    results = Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow'"
    point = time_point(time_entity[:value][:Time][:Single][:value])
    assert_includes VALID_GRAINS, point[:grain],
      "Expected grain to be one of #{VALID_GRAINS.inspect}"
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_parity_with_wafer_inc_duckling
    results = Duckling.parse("Call me tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    assert_operator results.size, :>=, 1, "expected at least one entity for 'Call me tomorrow'"
    entity = results.find { |r| r[:body] == "tomorrow" }
    refute_nil entity, "expected an entity with body: 'tomorrow'"
    assert_equal :time, entity[:dim]
    single = entity[:value][:Time][:Single]
    point = time_point(single[:value])
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
    assert_kind_of Array, single[:values]
    assert single[:values].size > 0, "expected :values to be a non-empty Array"
  end

  def test_parses_interval
    results = Duckling.parse("from 3pm to 5pm", locale: "en", reference_time: REFERENCE_TIME)
    assert results.size > 0
    entity = results.first
    assert_equal :time, entity[:dim]
    interval = entity[:value][:Time][:Interval]
    refute_nil interval, "Expected :value to be tagged :Interval, got: #{entity[:value].inspect}"
    assert interval.key?(:from), "interval value should have :from"
    assert interval.key?(:to), "interval value should have :to"
    from = time_point(interval[:from])
    assert_equal :hour, from[:grain]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), from[:value]
    to = time_point(interval[:to])
    assert_equal :hour, to[:grain]
    # duckling represents interval :to as the exclusive hour boundary, not the
    # literal named time — "5pm" (17:00) surfaces as 18:00. Verified against
    # wafer-inc-duckling's own tests/time_corpus.rs (e.g. "3-4pm" -> to 17:00).
    assert_equal Time.new(2013, 2, 12, 18, 0, 0, "-02:00"), to[:value]
  end

  def test_time_reference_time_preserves_utc_offset_for_instant_results
    results = Duckling.parse("in one hour", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'in one hour'"
    point = time_point(entity[:value][:Time][:Single][:value])
    assert_kind_of Time, point[:value]
    assert_equal REFERENCE_TIME + 3600, point[:value]
    # Time#== only compares the instant, not utc_offset — assert this
    # explicitly since preserving the offset is the whole point of this test.
    assert_equal(-7200, point[:value].utc_offset)
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
    point = time_point(entity[:value][:Time][:Single][:value])
    assert_kind_of Time, point[:value]
    assert_equal REFERENCE_TIME + 3600, point[:value]
    assert_equal(-7200, point[:value].utc_offset)
  end
end
