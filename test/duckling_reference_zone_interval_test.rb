# frozen_string_literal: true

require_relative "test_helper"

# Issue #85 (DST-aware reference_zone:) / hill layer "interval-endpoints":
# an Interval-shaped time result's `from` and `to` legs must each be
# reinterpreted against `reference_zone:` INDEPENDENTLY, using each leg's own
# date's real UTC offset — not a single offset borrowed from reference_time:
# or from just one of the two legs. "from March 7th 2026 3:00am to March 9th
# 2026 3:00am" straddles the US spring-forward transition at 2:00am local on
# 2026-03-08: the `from` leg (March 7, still standard time) must resolve to
# EST (UTC-5) while the `to` leg (March 9, already daylight time) must
# resolve to EDT (UTC-4).
class DucklingReferenceZoneIntervalTest < Minitest::Test
  def test_interval_legs_resolve_independently_across_dst_transition
    results = Duckling.parse(
      "from March 7th 2026 3:00am to March 9th 2026 3:00am",
      locale: "en",
      dims: ["time"],
      reference_time: REFERENCE_TIME,
      reference_zone: "America/New_York"
    )
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "expected a :time entity, got: #{results.inspect}"

    interval = entity[:value][:Time][:Interval]
    from_time = interval[:from][:Naive][:value]
    to_time = interval[:to][:Naive][:value]

    assert_equal(-18000, from_time.utc_offset,
      "expected the `from` leg (March 7, before the spring-forward " \
      "transition) to resolve to America/New_York's EST offset (-18000), " \
      "got #{from_time.utc_offset} (#{from_time.inspect})")

    assert_equal(-14400, to_time.utc_offset,
      "expected the `to` leg (March 9, after the spring-forward " \
      "transition) to resolve to America/New_York's EDT offset (-14400), " \
      "got #{to_time.utc_offset} (#{to_time.inspect})")
  end
end
