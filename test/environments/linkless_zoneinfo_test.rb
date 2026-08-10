# frozen_string_literal: true

require "test_helper"

# Environment contract for the links-less zoneinfo environment
# (bin/build-linkless-zoneinfo + DUCKLING_ZONEINFO_DIR). Run directly by the
# CI step that builds the stripped tree; the suite does not load it. Run by
# hand against a built tree:
#
#   bin/build-linkless-zoneinfo /tmp/linkless-zoneinfo
#   DUCKLING_ZONEINFO_DIR=/tmp/linkless-zoneinfo bundle exec ruby -Ilib -Itest test/environments/linkless_zoneinfo_test.rb
#
# See docs/tz-database-axis.md.
class LinklessZoneinfoTest < Minitest::Test
  def test_the_environment_has_no_backward_compat_links
    refute TZCapabilities.supports?(:backward_compat_links),
      "expected a links-less datasource, got #{TZCapabilities.datasource_description}. " \
      "If DUCKLING_ZONEINFO_DIR points at a stripped tree, the strip stopped working."
  end

  # The build script's own check catches only under-stripping, so the count
  # must stay in a real links-less host's range (497 when transcribed).
  def test_the_environment_keeps_the_rest_of_the_database
    count = TZInfo::Timezone.all_identifiers.size

    assert_operator count, :>, 400,
      "expected a links-less tree to keep the canonical zones (~497), got #{count} — " \
      "the strip is deleting entries a stock host keeps"
    assert_operator count, :<, 560,
      "expected the backward-compat names to be gone (~497), got #{count} — " \
      "the strip is leaving entries a stock host does not have"
  end

  # Pins the remedy wording for a *real* backward-compat name; the
  # every-environment remedy test in DucklingTest passes a typo'd one.
  def test_us_eastern_raises_naming_both_remedies
    error = assert_raises(ArgumentError) do
      Duckling.parse("in 3 hours", locale: "en", dims: ["time"], reference_zone: "US/Eastern")
    end

    assert_includes error.message, "tzinfo-data",
      "expected the gem remedy for the missing backward-compat links, got: #{error.message.inspect}"
    assert_includes error.message, "tzdata-legacy",
      "expected the system-package remedy for the missing backward-compat links, got: #{error.message.inspect}"
  end
end
