# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class DucklingReferenceZoneWithoutReferenceTimeTest < Minitest::Test
  def test_reference_zone_without_reference_time_anchors_at_current_time_in_zone
    fixed_now = Time.new(2013, 6, 15, 10, 0, 0, "-04:00") # EDT "now"
    Time.stub :now, fixed_now do
      results = Duckling.parse("today", locale: "en", reference_zone: "America/New_York")
      entity = results.find { |r| r[:dim] == :time }
      refute_nil entity, "Expected a :time dimension result for 'today'"
      assert_kind_of Time, entity[:value][:value]
      assert_equal Time.new(2013, 6, 15, 0, 0, 0, "-04:00"), entity[:value][:value]
      assert_equal(-4 * 3600, entity[:value][:value].utc_offset)
    end
  end
end
