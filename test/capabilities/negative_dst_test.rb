# frozen_string_literal: true

require "test_helper"

# Europe/Dublin's fall-back overlap: the first occurrence is selected by
# position, not by tzinfo's dst? flag — negative DST inverts the flag, so a
# flag lookup returns the post-transition occurrence, an hour off. Loads only
# where the database models negative DST. See docs/tz-database-axis.md.
class NegativeDstTest < Minitest::Test
  def test_reference_zone_overlap_takes_first_occurrence_in_negative_dst_zones
    # The premise, asserted with the same predicate the loader consults: data
    # that stopped discriminating must fail here, not pass vacuously.
    assert TZCapabilities.models_negative_dst?,
      "expected Europe/Dublin to be modelled with negative DST (winter carrying tzinfo's " \
      "dst? flag); without that inversion this test cannot tell periods.first from a " \
      "dst?-flag lookup"

    reference_time = Time.new(2026, 9, 1, 12, 0, 0, "+01:00")
    entity = entity_for("October 25 2026 1:30am", :time,
      reference_time: reference_time, reference_zone: "Europe/Dublin")
    resolved = single_point(entity)[:value]

    assert_equal 1, resolved.hour, "expected the 1:30 wall clock preserved through the overlap, got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal 3600, resolved.utc_offset,
      "expected the first (pre-transition) occurrence (IST, +3600), got #{resolved.inspect}"
  end
end
