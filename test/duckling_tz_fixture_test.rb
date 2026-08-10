# frozen_string_literal: true

require "test_helper"

# The DST edges of `reference_zone:`, asserted against zones compiled here
# (test/fixtures/tz/): identical on every host and vintage, where a real zone
# is a moving target. Reached through Duckling.parse to stay outside-in.
# See docs/tz-database-axis.md.
class DucklingTZFixtureTest < Minitest::Test
  include TZFixtures::Datasource

  # If the host's zones leaked in, the tests below go back to being host-dependent.
  def test_fixture_datasource_replaces_the_hosts_zones
    assert_equal %w[Fixture/HalfHourGap Fixture/LateGap Fixture/NegativeDst],
      TZInfo::Timezone.all_identifiers.sort
  end

  # The premise of the overlap test, asserted separately so its loss fails
  # loudly: winter must carry the dst? flag, or position and flag agree.
  def test_negative_dst_fixture_reports_winter_as_the_dst_period
    zone = TZInfo::Timezone.get("Fixture/NegativeDst")

    assert zone.period_for(Time.utc(2026, 1, 15)).dst?,
      "expected the fixture's winter period to carry tzinfo's dst? flag — without that " \
      "inversion the overlap test below cannot distinguish position from flag"
    refute zone.period_for(Time.utc(2026, 7, 15)).dst?,
      "expected the fixture's summer period to be plain standard time"
  end

  # The 2026-10-25 transition takes the zone from +01:00 to +00:00, so 01:30
  # local happens twice. First occurrence by position (+3600); a dst?-flag
  # lookup picks the other one, an hour late.
  def test_negative_dst_overlap_takes_the_first_occurrence
    reference_time = Time.new(2026, 9, 1, 12, 0, 0, "+01:00")
    entity = entity_for("October 25 2026 1:30am", :time,
      reference_time: reference_time, reference_zone: "Fixture/NegativeDst")
    resolved = single_point(entity)[:value]

    assert_equal 1, resolved.hour,
      "expected the 1:30 wall clock preserved through the overlap, got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal 3600, resolved.utc_offset,
      "expected the first (pre-transition) occurrence, +3600, not the dst-flagged " \
      "one at +0, got #{resolved.inspect}"
  end

  # Springs forward 30 minutes at 02:00 on 2026-10-04, so a skipped 02:15
  # lands on 02:45. Direct call: no English expression lands reliably inside
  # a 30-minute window.
  def test_half_hour_gap_shifts_by_the_transitions_own_width
    zone = TZInfo::Timezone.get("Fixture/HalfHourGap")
    skipped = Time.new(2026, 10, 4, 2, 15, 0, "+10:30")

    resolved = Duckling.send(:local_time_in_zone, zone, skipped)

    assert_equal 2, resolved.hour, "expected a 30-minute shift to 02:45, got #{resolved.inspect}"
    assert_equal 45, resolved.min, "expected a 30-minute shift to 02:45, got #{resolved.inspect}"
    assert_equal zone.period_for(resolved).observed_utc_offset, resolved.utc_offset,
      "expected the resolved Time to carry the offset the zone observes at its own instant"
  end

  # 23:00 local at -02:00 puts the transition at 01:00 UTC the next day.
  def test_late_gap_resolves_when_the_transition_is_past_utc_midnight
    reference_time = Time.new(2026, 3, 28, 12, 0, 0, "-02:00")
    entity = entity_for("March 28 2026 11:30pm", :time,
      reference_time: reference_time, reference_zone: "Fixture/LateGap")
    resolved = single_point(entity)[:value]

    assert_equal 0, resolved.hour,
      "expected the skipped 23:30 wall clock to shift forward past the gap to 00:30, got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal 29, resolved.day, "expected the shift to land on the next day, got #{resolved.inspect}"
    assert_equal(-3600, resolved.utc_offset,
      "expected the post-transition offset (-3600), got #{resolved.inspect}")
  end
end
