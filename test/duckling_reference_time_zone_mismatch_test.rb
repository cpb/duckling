# frozen_string_literal: true

require "test_helper"

class DucklingReferenceTimeZoneMismatchTest < Minitest::Test
  def test_reference_time_utc_offset_disagreeing_with_zone_raises_argument_error
    reference_time = Time.new(2013, 6, 15, 12, 0, 0, "+00:00") # UTC, disagrees with EDT -04:00
    error = assert_raises(ArgumentError) do
      Duckling.parse("tomorrow", locale: "en",
        reference_time: reference_time, reference_zone: "America/New_York")
    end
    assert_match(/utc_offset/i, error.message,
      "expected a mismatch error mentioning utc_offset, got: #{error.message.inspect}")
  end
end
