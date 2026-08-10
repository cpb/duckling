# frozen_string_literal: true

require "test_helper"

# Environment contract for the Alpine environment (the tz-containers job).
# Invoked directly by that CI step, never loaded by the suite. Alpine ships
# vanguard tzdata, which models negative DST; an image that silently lost it
# would run less, not fail — so rearguard-or-absent data here is a red step.
# See docs/tz-database-axis.md.
class AlpineVanguardTest < Minitest::Test
  def test_the_environment_models_negative_dst
    assert TZCapabilities.models_negative_dst?,
      "expected vanguard tzdata modelling negative DST, got #{TZCapabilities.datasource_description}. " \
      "Is tzdata installed in the image?"
  end
end
