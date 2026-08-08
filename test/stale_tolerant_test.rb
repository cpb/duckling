# frozen_string_literal: true

require "test_helper"

# stale_tolerant (test_helper.rb) decides whether a failure means "this tz
# database cannot answer the question" or "something is broken". Getting that
# wrong in the permissive direction is invisible: the skip manifest records
# the same green either way, so a genuine regression would be filed as an
# expected coverage gap and nobody would look again.
#
# Every case here runs against the fixture zoneinfo, whose three zones include
# none of the ones the probes ask about. That makes all capabilities absent on
# every leg, so these assertions exercise the permissive branch — the
# dangerous one — no matter which database the run is using.
class StaleTolerantTest < Minitest::Test
  def setup
    @previous_datasource = TZInfo::DataSource.get
    TZInfo::DataSource.set(:zoneinfo, TZFixtures.zoneinfo_dir)
  end

  def teardown
    TZInfo::DataSource.set(@previous_datasource)
  end

  # The premise the rest of the file depends on. Asserted rather than assumed,
  # because if a probe ever answered true here every test below would pass by
  # taking the wrong branch.
  def test_the_fixture_datasource_reports_every_capability_absent
    TZCapabilities::CAPABILITIES.each_key do |capability|
      refute TZCapabilities.supports?(capability),
        "expected #{capability} to be absent from a datasource holding only the fixture zones"
    end
  end

  # An ArgumentError naming reference_zone: is what timezone_for raises for an
  # identifier the database does not have — a real absent capability.
  def test_converts_a_reference_zone_argument_error_into_a_named_skip
    skipped = assert_raises(Minitest::Skip) do
      stale_tolerant(:backward_compat_links) do
        raise ArgumentError, 'invalid reference_zone: "US/Eastern" (resolved against ...)'
      end
    end

    assert_includes skipped.message, "backward_compat_links",
      "expected the skip to name the capability it is waiting on, got: #{skipped.message.inspect}"
  end

  # A failed assertion is the stale-vintage shape: the zone resolves, and
  # answers with different rules.
  def test_converts_a_failed_assertion_into_a_named_skip
    skipped = assert_raises(Minitest::Skip) do
      stale_tolerant(:greenland_2023_rules) { flunk "expected -3600, got -7200" }
    end

    assert_includes skipped.message, "greenland_2023_rules"
  end

  # The case the message guard exists for. An invalid locale:/dims: value
  # raises plain ArgumentError, as does a bad Time.new in a test's own setup —
  # none of which says anything about the tz database. Without the guard each
  # would become a manifest-approved skip on any leg lacking the capability.
  def test_re_raises_an_argument_error_unrelated_to_the_tz_database
    error = assert_raises(ArgumentError) do
      stale_tolerant(:greenland_2023_rules) { raise ArgumentError, 'unsupported locale: "xx"' }
    end

    assert_equal 'unsupported locale: "xx"', error.message,
      "expected an unrelated ArgumentError to reach the caller unchanged rather than " \
      "becoming a skip"
  end

  # An unknown capability name is a typo at the call site, not a statement
  # about any database, and must not be swallowed by the rescue it sits in.
  def test_rejects_an_unknown_capability_name
    error = assert_raises(ArgumentError) do
      stale_tolerant(:no_such_capability) { flunk "unreachable" }
    end

    assert_includes error.message, "unknown tz capability"
  end
end
