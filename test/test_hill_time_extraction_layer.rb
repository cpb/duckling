# frozen_string_literal: true

require "test_helper"

class TestHillTimeExtractionLayer < Minitest::Test
  def test_parses_time_dimension
    results = Duckling.parse("tomorrow", locale: "en")
    assert results.any? { |r| r[:dim] == :time || r["dim"] == "time" }, "Expected a :time dimension result for 'tomorrow'"
  end
end
