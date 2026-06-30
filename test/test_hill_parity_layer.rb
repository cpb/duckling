# frozen_string_literal: true

require "test_helper"

class TestHillParityLayer < Minitest::Test
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
