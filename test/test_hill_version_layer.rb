# frozen_string_literal: true

require "test_helper"

class TestHillVersionLayer < Minitest::Test
  def test_version_is_0_2_0
    assert_equal "0.2.0", Duckling::VERSION
  end
end
