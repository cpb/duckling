# frozen_string_literal: true

require "test_helper"

# Environment contract for the system-zoneinfo-with-links environment
# (Debian + tzdata-legacy; the tz-containers job). Run directly by that CI
# step; the suite does not load it. An environment that lost the links would
# silently run less, so their absence here is a red step.
# See docs/tz-database-axis.md.
class SystemZoneinfoLinksTest < Minitest::Test
  def test_the_environment_has_the_backward_compat_links
    assert TZCapabilities.supports?(:backward_compat_links),
      "expected the backward-compat links (tzdata-legacy), got #{TZCapabilities.datasource_description}. " \
      "Did the image stop shipping the package, or the step stop installing it?"
  end
end
