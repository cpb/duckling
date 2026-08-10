# frozen_string_literal: true

require "test_helper"

# Environment contract for the two stale-vintage environments (tzinfo-data
# pinned to 1.2022.7; host zoneinfo rolled back by bin/build-stale-zoneinfo).
# Run directly by those CI steps; the suite does not load it. A stale
# database's dangerous failure is a wrong answer, so the wrong answer is
# asserted on purpose. See docs/tz-database-axis.md.
class StaleVintageTest < Minitest::Test
  def test_the_environment_lacks_greenlands_2023a_rules
    refute TZCapabilities.supports?(:greenland_2023_rules),
      "expected a pre-2023a datasource, got #{TZCapabilities.datasource_description}. " \
      "The tzinfo-data pin (1.2022.7) or the America/Nuuk rollback stopped taking effect."
  end

  # No reference_time: the two stale sources disagree about the exact
  # transition times, so the offset is pinned against the database's own
  # answer for that instant.
  def test_america_nuuk_answers_with_pre_2023a_rules
    entity = entity_for("March 28 2026 11:30pm", :time, reference_zone: "America/Nuuk")
    resolved = single_point(entity)[:value]

    assert_equal 23, resolved.hour,
      "expected the old rules to keep the 23:30 wall clock (no gap), got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal 28, resolved.day, "expected no shift into the next day, got #{resolved.inspect}"

    real_offset = TZInfo::Timezone.get("America/Nuuk").period_for(resolved).observed_utc_offset
    assert_equal real_offset, resolved.utc_offset,
      "expected the resolved offset to be the one the database observes at that instant, " \
      "got #{resolved.utc_offset} (database says #{real_offset})"
  end
end
