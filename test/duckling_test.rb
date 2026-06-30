# frozen_string_literal: true

require "test_helper"

class DucklingTest < Minitest::Test
  def test_parse_returns_array
    assert_kind_of Array, Duckling.parse("tomorrow", locale: "en")
  end

  def test_parse_result_shape
    results = Duckling.parse("at 3pm", locale: "en")
    assert results.size > 0, "Expected at least one result from Duckling.parse"
    first = results.first
    assert first.key?(:body), "Expected result to have :body key"
    assert first.key?(:start), "Expected result to have :start key"
    assert first.key?(:end), "Expected result to have :end key"
    assert first.key?(:dim), "Expected result to have :dim key"
    assert first.key?(:value), "Expected result to have :value key"
  end

  def test_parses_time_dimension
    results = Duckling.parse("tomorrow", locale: "en")
    assert results.any? { |r| r[:dim] == :time || r["dim"] == "time" }, "Expected a :time dimension result for 'tomorrow'"
  end

  def test_parity_with_wafer_inc_duckling
    results = Duckling.parse("Call me tomorrow", locale: "en")
    assert_operator results.size, :>=, 1, "expected at least one entity for 'Call me tomorrow'"
    entity = results.find { |r| (r[:body] || r["body"]) == "tomorrow" }
    refute_nil entity, "expected an entity with body: 'tomorrow'"
    dim = entity[:dim] || entity["dim"]
    assert_includes ["time", :time], dim, "expected dim to be :time for 'tomorrow'"
    grain = (entity[:value] || entity["value"] || {})[:grain] || (entity[:value] || entity["value"] || {})["grain"]
    assert_equal "day", grain, "expected grain: 'day' for 'tomorrow'"
  end
end
