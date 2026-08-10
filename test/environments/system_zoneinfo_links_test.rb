# frozen_string_literal: true

require "test_helper"

# Environment contract for the system-zoneinfo-with-links environment
# (Debian + the tzdata-legacy package — see the tz-containers job in
# .github/workflows/main.yml): invoked directly by that CI step, never loaded
# by the suite.
#
# The backward-compat capability tests (test/capabilities/) load wherever the
# probe finds the links — which means an environment that *lost* them would
# quietly run less, not fail. This contract is the loud half of that
# arrangement: this environment exists to have the links, so their absence
# here is a red step rather than a smaller suite.
class SystemZoneinfoLinksTest < Minitest::Test
  def test_the_environment_has_the_backward_compat_links
    assert TZCapabilities.supports?(:backward_compat_links),
      "expected the backward-compat links (tzdata-legacy), got #{TZCapabilities.datasource_description}. " \
      "Did the image stop shipping the package, or the step stop installing it?"
  end
end
