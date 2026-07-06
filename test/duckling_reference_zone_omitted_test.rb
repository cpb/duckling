# frozen_string_literal: true

require "test_helper"

class DucklingReferenceZoneOmittedTest < Minitest::Test
  def test_omitting_reference_zone_keeps_single_fixed_offset_behavior
    reference_time = Time.new(2013, 1, 15, 4, 30, 0, "-05:00") # EST
    results = Duckling.parse("june 15", locale: "en", reference_time: reference_time)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'june 15'"
    assert_kind_of Time, entity[:value][:value]
    # Without reference_zone:, today's behavior applies reference_time's own
    # fixed offset uniformly, even though America/New_York (the zone this
    # reference_time happens to represent) is really on EDT (-04:00) by
    # June 15 -- this pins that unchanged default so the reference_zone:
    # feature can never become accidentally mandatory.
    assert_equal Time.new(2013, 6, 15, 0, 0, 0, "-05:00"), entity[:value][:value]
    assert_equal(-5 * 3600, entity[:value][:value].utc_offset)
  end
end
