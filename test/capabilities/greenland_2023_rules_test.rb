# frozen_string_literal: true

require "test_helper"

# America/Nuuk springs forward at 23:00 local while at UTC-2, so the
# transition instant falls past the next UTC midnight. Loads only where the
# database carries the 2023a rules; a stale vintage resolves the zone and
# answers with the old rules, pinned by test/environments/stale_vintage_test.rb.
# See docs/tz-database-axis.md.
class Greenland2023RulesTest < Minitest::Test
  def test_reference_zone_resolves_gap_late_in_local_day
    reference_time = Time.new(2026, 3, 28, 12, 0, 0, "-02:00")
    entity = entity_for("March 28 2026 11:30pm", :time,
      reference_time: reference_time, reference_zone: "America/Nuuk")
    resolved = single_point(entity)[:value]

    assert_equal 0, resolved.hour,
      "expected the skipped 23:30 wall clock to shift forward past the gap to 00:30, got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal 29, resolved.day, "expected the shift to land on the next day, got #{resolved.inspect}"
    assert_equal(-3600, resolved.utc_offset,
      "expected the post-transition offset (UTC-1, -3600), got #{resolved.inspect}")
  end
end
