# frozen_string_literal: true

require "test_helper"

# "US/Eastern" is a real IANA identifier — a link to America/New_York in the
# `backward` file — and tzinfo-data carries it. Debian and Ubuntu moved the
# backward file into a separate `tzdata-legacy` package that is not installed
# by default, so a stock host is missing roughly a hundred names this one
# stands for.
#
# Since this gem does not depend on tzinfo-data, a links-less host is a
# supported configuration, and the honest answer there is that the zone does
# not resolve. No shim, no bundled links table — so this test cannot pass
# everywhere. It therefore loads only where the probe finds the links (see
# the loader at the bottom of test_helper.rb). Where they are absent, the
# failure is a *diagnosable* ArgumentError, pinned on every host by
# DucklingTest#test_reference_zone_error_names_the_tz_datasource and on a
# built links-less host by test/environments/linkless_zoneinfo_test.rb.
class BackwardCompatLinksTest < Minitest::Test
  def test_reference_zone_resolves_backward_compat_identifier
    entity = entity_for("March 7th 2026 3:00am", :time, reference_zone: "US/Eastern")
    resolved = single_point(entity)[:value]

    assert_equal(-18000, resolved.utc_offset,
      "expected US/Eastern to resolve like America/New_York (EST, -18000), got #{resolved.inspect}")

    # Where the link points, not just that it resolves: -18000 alone is
    # satisfied by any zone on EST that day, so it would pass against a link
    # aimed anywhere plausible.
    #
    # Compared behaviorally rather than via canonical_identifier, which
    # answers differently per datasource and would make this test fail on
    # exactly the hosts it is meant to pass on. tzinfo-data models links, so
    # US/Eastern reports America/New_York; compiled TZif carries no link
    # metadata, so a ZoneinfoDataSource reports US/Eastern as its own
    # canonical zone. Resolving both and comparing is true on either.
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
