# frozen_string_literal: true

require "test_helper"

class TestHillEntityShapeLayer < Minitest::Test
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
end
