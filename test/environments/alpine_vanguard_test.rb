# frozen_string_literal: true

require "test_helper"

# Environment contract for the Alpine environment (see the tz-containers job
# in .github/workflows/main.yml): invoked directly by that CI step, never
# loaded by the suite.
#
# Alpine ships vanguard tzdata, which models negative DST — the modelling
# axis that rearguard-compiled data (Ubuntu, macOS) flattens away. The
# capability-gated Dublin test (test/capabilities/negative_dst_test.rb)
# loads wherever the probe finds that modelling, so an Alpine image that
# silently lost it (say, a missing tzdata package leaving no database at all)
# would run less, not fail. This contract is the loud half: the environment
# exists to be vanguard, so rearguard-or-absent data here is a red step.
class AlpineVanguardTest < Minitest::Test
  def test_the_environment_models_negative_dst
    assert TZCapabilities.models_negative_dst?,
      "expected vanguard tzdata modelling negative DST, got #{TZCapabilities.datasource_description}. " \
      "Is tzdata installed in the image?"
  end
end
