# frozen_string_literal: true

require "test_helper"

# Issue #85 (DST-aware reference_time via reference_zone:): TimePoint::Instant
# results (e.g. "in 3 hours" — relative/duration-based, already resolved to an
# absolute instant by the underlying Rust crate against a single FixedOffset
# before this gem ever sees it) must NOT be reinterpreted by reference_zone:.
# That arithmetic imprecision is explicitly out of scope (tracked separately
# in issue #83) — reference_zone:'s DST awareness only applies to :Naive
# (wall-clock) results.
class DucklingReferenceZoneInstantTest < Minitest::Test
  def test_reference_zone_leaves_instant_result_unaffected
    without_zone = entity_for("in 3 hours", :time, reference_time: REFERENCE_TIME)
    with_zone = Duckling.parse(
      "in 3 hours",
      locale: "en",
      dims: ["time"],
      reference_time: REFERENCE_TIME,
      reference_zone: "America/New_York"
    ).find { |r| r[:dim] == :time }

    instant_without = without_zone[:value][:Time][:Single][:value][:Instant][:value]
    instant_with = with_zone[:value][:Time][:Single][:value][:Instant][:value]

    assert_equal instant_without, instant_with,
      "expected reference_zone: to leave a TimePoint::Instant result's resolved Time completely unaffected"

    # reference_zone: must be validated as a real IANA zone name — an
    # unrecognized identifier should be rejected rather than silently
    # accepted and ignored.
    assert_raises(ArgumentError) do
      Duckling.parse(
        "in 3 hours",
        locale: "en",
        dims: ["time"],
        reference_time: REFERENCE_TIME,
        reference_zone: "Not/A/Real/Zone"
      )
    end
  end
end
