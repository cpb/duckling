# frozen_string_literal: true

require "test_helper"

# "US/Eastern" is a link to America/New_York in IANA's `backward` file.
# Loads only where the database carries the links; where they are absent the
# diagnosable ArgumentError is pinned by DucklingTest and
# test/environments/linkless_zoneinfo_test.rb. See docs/tz-database-axis.md.
class BackwardCompatLinksTest < Minitest::Test
  def test_reference_zone_resolves_backward_compat_identifier
    entity = entity_for("March 7th 2026 3:00am", :time, reference_zone: "US/Eastern")
    resolved = single_point(entity)[:value]

    assert_equal(-18000, resolved.utc_offset,
      "expected US/Eastern to resolve like America/New_York (EST, -18000), got #{resolved.inspect}")

    # Compare behaviorally: canonical_identifier differs per datasource
    # (tzinfo-data models links; compiled TZif carries no link metadata).
    canonical = single_point(
      entity_for("March 7th 2026 3:00am", :time, reference_zone: "America/New_York")
    )[:value]

    assert_equal canonical, resolved,
      "expected US/Eastern to resolve to the same instant as America/New_York"
    assert_equal canonical.utc_offset, resolved.utc_offset,
      "expected US/Eastern to carry the same offset as America/New_York — Time#== compares " \
      "only the instant, so the offset needs its own assertion"
  end
end
