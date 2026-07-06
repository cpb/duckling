# frozen_string_literal: true

require "test_helper"

class DucklingReferenceZoneDstTransitionTest < Minitest::Test
  def test_naive_result_after_dst_transition_gets_post_transition_offset
    reference_time = Time.new(2013, 1, 15, 4, 30, 0, "-05:00") # EST
    results = Duckling.parse("june 15", locale: "en",
      reference_time: reference_time, reference_zone: "America/New_York")
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'june 15'"
    assert_kind_of Time, entity[:value][:value]
    # America/New_York is on EDT (-04:00) by June 15 2013 (2013 DST ran
    # March 10 - November 3), not the reference's own EST (-05:00) offset --
    # applying the real zone's per-date offset is the whole point of
    # reference_zone:.
    assert_equal Time.new(2013, 6, 15, 0, 0, 0, "-04:00"), entity[:value][:value]
    assert_equal(-4 * 3600, entity[:value][:value].utc_offset)
  end
end
