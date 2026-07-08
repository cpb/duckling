# frozen_string_literal: true

require_relative "test_helper"

# Characterizes apply_reference_zone's loud-failure behavior when a :time
# entity's :value doesn't match the known Single/Interval shape — a future
# drift in the Rust side's serialized shape must not pass unnoticed.
class DucklingReferenceZoneUnrecognizedShapeTest < Minitest::Test
  def test_raises_on_unrecognized_time_value_shape
    malformed_entity = {dim: :time, value: {Time: {NotARealTag: {}}}}

    assert_raises(RuntimeError) do
      Duckling.apply_reference_zone([malformed_entity], "America/New_York")
    end
  end
end
