# frozen_string_literal: true

require "test_helper"

# Documents a known, out-of-scope limitation (issue #83): TimePoint::Instant-
# grain arithmetic (e.g. "in 5 months") is resolved entirely inside the
# wrapped wafer-inc-duckling crate against a single chrono::FixedOffset,
# before the result ever reaches this gem -- so reference_zone: cannot
# correct it without upstream zone-aware Context support. This test is
# intentionally skipped; it pins the exact expected (currently unmet)
# behavior for when #83 lands.
class DucklingInstantGrainDstLimitationTest < Minitest::Test
  def test_instant_grain_arithmetic_across_dst_transition_remains_imprecise
    skip "known limitation tracked in #83 -- Instant-grain arithmetic is not reference_zone:-aware"

    reference_time = Time.new(2013, 1, 15, 4, 30, 0, "-05:00") # EST
    results = Duckling.parse("in 5 months", locale: "en",
      reference_time: reference_time, reference_zone: "America/New_York")
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'in 5 months'"
    # 2013-01-15 + 5 months = 2013-06-15, which is under EDT (-04:00) in
    # America/New_York -- but Instant-grain arithmetic happens inside the
    # wrapped crate against reference_time's own fixed EST offset, so this
    # currently (wrongly) comes back at -05:00 instead of -04:00.
    assert_equal(-4 * 3600, entity[:value][:value].utc_offset)
  end
end
