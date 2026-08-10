# frozen_string_literal: true

require "test_helper"

# The DST edges of `reference_zone:`, asserted against zones compiled here
# rather than borrowed from the host.
#
# Each of these edges is a moving target when pinned by a real zone.
# Europe/Dublin is only a negative-DST zone where tzdata is compiled in
# vanguard format — on a rearguard host (Debian, Ubuntu) a test against it
# keeps passing and stops distinguishing anything. America/Nuuk grew its
# late-in-the-day gap in tzdata 2023a and answered to a different name before
# 2020a. Australia/Lord_Howe is the last zone in use with a 30-minute gap, so
# that coverage rests on one zone's continued existence.
#
# These fixtures answer the same questions on every host and every vintage.
# They do not replace the real-zone tests — those still assert that the real
# world behaves as expected where the database can say — but they keep the
# behavior itself covered on the environments where the real zones cannot answer.
#
# Reached through Duckling.parse wherever an English expression can produce
# the wall clock in question, so the coverage is outside-in and not merely a
# unit test of local_time_in_zone. The half-hour gap is the one exception —
# no English expression lands reliably inside a 30-minute window, so that test
# calls local_time_in_zone directly and says so. That outside-in default is
# also why these are fixture zones rather than Ruby doubles: timezone_for
# builds the zone internally from TZInfo::Timezone.get, so nothing injectable
# reaches it from a test.
class DucklingTZFixtureTest < Minitest::Test
  include TZFixtures::Datasource

  # The fixture directory must expose its own zones and nothing else — if the
  # host's zoneinfo leaked in, the tests below would silently go back to being
  # host-dependent, which is the failure mode they exist to remove.
  def test_fixture_datasource_replaces_the_hosts_zones
    assert_equal %w[Fixture/HalfHourGap Fixture/LateGap Fixture/NegativeDst],
      TZInfo::Timezone.all_identifiers.sort
  end

  # The premise check for the overlap test below, asserted separately so its
  # loss would be a failure rather than a quiet weakening: tzinfo must report
  # this zone's *winter* as the dst? period. That inversion is what makes
  # "first occurrence" and "the dst occurrence" different answers at all.
  def test_negative_dst_fixture_reports_winter_as_the_dst_period
    zone = TZInfo::Timezone.get("Fixture/NegativeDst")

    assert zone.period_for(Time.utc(2026, 1, 15)).dst?,
      "expected the fixture's winter period to carry tzinfo's dst? flag — without that " \
      "inversion the overlap test below cannot distinguish position from flag"
    refute zone.period_for(Time.utc(2026, 7, 15)).dst?,
      "expected the fixture's summer period to be plain standard time"
  end

  # A fall-back overlap resolves to the first occurrence *by position*, which
  # in a negative-DST zone is the one tzinfo does NOT flag as dst. The
  # transition at 01:00 UTC on 2026-10-25 takes the zone from +01:00 back to
  # +00:00, so 01:30 local happens twice; the first is +3600.
  #
  # ActiveSupport::TimeZone#local returns the other one here, via
  # period_for_local's dst=true default — the deliberate departure documented
  # on local_time_in_zone. Picking by flag would give an instant an hour late.
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

  # A gap shifts forward by the transition's own width. This zone springs
  # forward 30 minutes at 02:00 on 2026-10-04, so a skipped 02:15 lands on
  # 02:45 — where ActiveSupport's hardcoded `@time += 1.hour` retry overshoots
  # to 03:15.
  #
  # Exercises local_time_in_zone directly rather than through Duckling.parse:
  # no English time expression reliably produces a wall clock inside a
  # 30-minute window.
  def test_half_hour_gap_shifts_by_the_transitions_own_width
    zone = TZInfo::Timezone.get("Fixture/HalfHourGap")
    skipped = Time.new(2026, 10, 4, 2, 15, 0, "+10:30")

    resolved = Duckling.send(:local_time_in_zone, zone, skipped)

    assert_equal 2, resolved.hour, "expected a 30-minute shift to 02:45, got #{resolved.inspect}"
    assert_equal 45, resolved.min, "expected a 30-minute shift to 02:45, got #{resolved.inspect}"
    assert_equal zone.period_for(resolved).observed_utc_offset, resolved.utc_offset,
      "expected the resolved Time to carry the offset the zone observes at its own instant"
  end

  # A gap late in the local day in a negative-offset zone puts the
  # transition's UTC instant past the *next* UTC midnight: 23:00 local at
  # -02:00 is 01:00 UTC the following day. gap_delta's scan window is centered
  # on the skipped wall clock read as UTC for exactly this reason — anchored
  # to the UTC midnight of the wall clock's date instead, it misses the
  # transition and gap_delta crashes with NoMethodError on a nil `find`.
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
