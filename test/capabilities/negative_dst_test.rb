# frozen_string_literal: true

require "test_helper"

# The fall-back "first occurrence" is selected by position (periods.first in
# local_time_in_zone), not by tzinfo's dst flag: dst=true only means
# pre-transition where the earlier period observes DST, and negative-DST
# zones invert that — tzinfo models Europe/Dublin's winter GMT as its
# dst?==true period, so flag-based resolution there returns the
# post-transition occurrence, an hour off as an instant. Dublin's 2026-10-25
# fall-back makes 01:30 ambiguous; the first occurrence is IST (+3600).
#
# This test's premise is entirely Dublin's negative DST, and some
# distributions compile tzdata in rearguard format, which strips it (Ubuntu
# 24.04 does; Debian trixie does not) — on such a host Dublin
# is an ordinary positive-DST zone, position and dst? flag agree, and the
# assertions below stop distinguishing them while still passing. That silent
# degradation is worse than a failure, so this file loads only where the
# database models negative DST at all (see the loader at the bottom of
# test_helper.rb), and DucklingTZFixtureTest asserts the same distinction
# against Fixture/NegativeDst, which is negative-DST on every host because it
# is compiled here rather than shipped.
class NegativeDstTest < Minitest::Test
  def test_reference_zone_overlap_takes_first_occurrence_in_negative_dst_zones
    # The premise, asserted rather than assumed. The probe already gated this
    # file's loading; asserting again here is the tripwire for the day the
    # probe or the IANA data drifts — a future tzdata that stops modelling
    # Dublin with negative DST turns this red wherever the file still loads,
    # instead of letting the assertions below pass without distinguishing
    # anything.
    #
    # Asserted via the same predicate the loader consults, not a second copy
    # of the zone and date. Two definitions could drift, and the drift would
    # surface as this file testing nothing on a host it believes is capable.
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
