# frozen_string_literal: true

require "test_helper"

# Issue #85 (re-implemented for #96): `reference_zone:` makes a `:Naive`
# (wall-clock) time result DST-aware by resolving its UTC offset against the
# real IANA zone for *that result's own date*, instead of the single fixed
# offset `reference_time:` provides today. US DST began 2026-03-08 02:00
# local (America/New_York): "spring forward" from EST (UTC-5) to EDT (UTC-4).
# A naive result dated just before that transition must resolve to -18000
# (EST); one dated just after must resolve to -14400 (EDT) — proving each
# result is resolved against its own date, not a single offset applied
# uniformly across both.
class DucklingReferenceZoneDstTransitionTest < Minitest::Test
  def test_naive_results_resolve_offset_per_date_across_dst_transition
    before_results = Duckling.parse(
      "March 7th 2026 3:00am",
      locale: "en",
      dims: ["time"],
      reference_time: REFERENCE_TIME,
      reference_zone: "America/New_York"
    )
    after_results = Duckling.parse(
      "March 9th 2026 3:00am",
      locale: "en",
      dims: ["time"],
      reference_time: REFERENCE_TIME,
      reference_zone: "America/New_York"
    )

    before_entity = before_results.find { |r| r[:dim] == :time }
    after_entity = after_results.find { |r| r[:dim] == :time }
    refute_nil before_entity, "expected a :time entity for 'March 7th 2026 3:00am', got: #{before_results.inspect}"
    refute_nil after_entity, "expected a :time entity for 'March 9th 2026 3:00am', got: #{after_results.inspect}"

    before_value = before_entity[:value][:Time][:Single][:value][:Naive][:value]
    after_value = after_entity[:value][:Time][:Single][:value][:Naive][:value]

    assert_equal(-18000, before_value.utc_offset,
      "Expected 'March 7th 2026' (before the 2026-03-08 America/New_York DST transition) " \
      "to resolve to EST (UTC-5, -18000s) when reference_zone: is given, got #{before_value.utc_offset}")
    assert_equal(-14400, after_value.utc_offset,
      "Expected 'March 9th 2026' (after the 2026-03-08 America/New_York DST transition) " \
      "to resolve to EDT (UTC-4, -14400s) when reference_zone: is given, got #{after_value.utc_offset}")
  end
end
