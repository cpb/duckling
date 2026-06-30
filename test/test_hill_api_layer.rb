# frozen_string_literal: true

require "test_helper"

class TestHillApiLayer < Minitest::Test
  def test_parse_returns_array
    assert_kind_of Array, Duckling.parse("tomorrow", locale: "en")
  end
end
