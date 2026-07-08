# frozen_string_literal: true

require_relative "test_helper"

# reference_zone: (new keyword, not yet supported by Duckling.parse) makes
# :Naive wall-clock time results DST-aware by resolving each result's UTC
# offset against the real IANA zone for that result's own date, instead of
# blindly inheriting reference_time's fixed offset. America/New_York springs
# forward from 2:00am straight to 3:00am on 2026-03-08, so "2:30am" that day
# is a local time that never actually occurs — it must raise rather than
# silently pick an arbitrary (wrong) offset.
class DucklingReferenceZoneDstGapTest < Minitest::Test
  def test_raises_argument_error_for_dst_spring_forward_gap
    reference_time = Time.new(2026, 3, 1, 9, 0, 0, "-05:00")

    assert_raises(ArgumentError) do
      Duckling.parse(
        "March 8 2026 2:30am",
        locale: "en",
        dims: ["time"],
        reference_time: reference_time,
        reference_zone: "America/New_York"
      )
    end
  end
end
