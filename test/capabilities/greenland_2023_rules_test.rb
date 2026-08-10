# frozen_string_literal: true

require "test_helper"

# A gap late in the local day has a transition instant past the *next* UTC
# midnight when the zone's offset is negative — America/Nuuk springs forward
# at 23:00 local while at UTC-2, putting the transition at 01:00 UTC the
# following day. gap_delta's scan window must therefore center on the
# skipped wall clock itself; anchoring it to the UTC midnight of the wall
# clock's date excluded such transitions, and the resulting nil made
# gap_delta crash with NoMethodError instead of resolving the gap.
#
# America/Nuuk only grew these rules in tzdata 2023a, and was named
# America/Godthab before 2020a, so this is the one assertion in the suite
# that a stale-but-otherwise-fine tz database gets wrong rather than
# missing: a 2021–2022 vintage resolves the zone happily at -03:00/-02:00
# with no gap anywhere near 23:30. This file therefore loads only where the
# database carries the 2023a rules (see the loader at the bottom of
# test_helper.rb); the stale answer itself is pinned positively by
# test/environments/stale_vintage_test.rb, and DucklingTZFixtureTest covers
# the same edge on Fixture/LateGap, which no vintage can move.
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
