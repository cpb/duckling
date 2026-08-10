# frozen_string_literal: true

require "test_helper"

# Environment contract for the two stale-vintage environments — tzinfo-data
# pinned to 1.2022.7, and host zoneinfo with America/Nuuk rolled back by
# bin/build-stale-zoneinfo. Invoked directly by those CI steps, never loaded
# by the suite — see "The tz-database axis" in AGENTS.md.
#
# A stale database's dangerous failure is not a missing zone but a wrong
# answer: America/Nuuk resolves fine and applies Greenland's pre-2023a rules.
# So the contract asserts the wrong answer itself. If the pin or the rollback
# silently stops taking effect, the capability-gated test
# (test/capabilities/greenland_2023_rules_test.rb) simply starts loading and
# passing — a green suite covering a different database than the environment
# exists for — while this contract turns red.
class StaleVintageTest < Minitest::Test
  def test_the_environment_lacks_greenlands_2023a_rules
    refute TZCapabilities.supports?(:greenland_2023_rules),
      "expected a pre-2023a datasource, got #{TZCapabilities.datasource_description}. " \
      "The tzinfo-data pin (1.2022.7) or the America/Nuuk rollback stopped taking effect."
  end

  # The wrong answer a 2021–2022 vintage gives, asserted positively: under
  # the old rules 2026-03-28 23:30 is an ordinary wall clock, where 2023a+
  # data skips it forward to 00:30 the next day. No reference_time: — the
  # expression is absolute, so none is needed, and the two stale sources this
  # contract serves (the 1.2022.7 gem, the zic-rolled zoneinfo) disagree
  # about the exact transition times, so no single fixed offset would pass
  # the offset-mismatch check on both. The offset is instead pinned against
  # the database's own answer for that instant.
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
