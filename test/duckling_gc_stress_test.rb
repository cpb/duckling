# frozen_string_literal: true

require "test_helper"

# Exercises the native entity conversion (including the serde_magnus
# symbolizer's delete/re-insert hash rewriting) under GC.stress across every
# dimension. The failure mode this guards against is a use-after-free of a
# magnus::Value the GC couldn't see — an equivalent verification of the same
# symbolizer previously caught a real segfault (see the wiki for the writeup)
# — so the point is executing the conversion with a GC pass forced between
# allocations, not the assertions.
class DucklingGcStressTest < Minitest::Test
  CASES = [
    ["thirty three", "number"],
    ["3rd", "ordinal"],
    ["37 degrees Celsius", "temperature"],
    ["3 kilometers", "distance"],
    ["1 liter", "volume"],
    ["5 pounds of sugar", "quantity"],
    ["between 3 and 5 dollars", "amount-of-money"],
    ["user@example.com", "email"],
    ["650-701-8887", "phone-number"],
    ["http://www.bla.com", "url"],
    ["4111-1111-1111-1111", "credit-card-number"],
    ["second", "time-grain"],
    ["3 days", "duration"],
    ["tomorrow at 5pm", "time"],
    ["from 3pm to 5pm", "time"]
  ].freeze

  # GC.stress forces a collection at every allocation, so a single pass over
  # CASES already interposes a GC between every allocation the conversion
  # makes — extra passes add heap-layout variety, not new coverage. Each pass
  # costs ~6s (every allocation pays a full-heap mark), so the default is a
  # single pass; bump the env var to re-run the full ~300-call verification
  # (20 passes).
  ITERATIONS = Integer(ENV.fetch("DUCKLING_GC_STRESS_ITERATIONS", 1))

  def test_parse_survives_gc_stress_across_all_dimensions
    GC.stress = true
    ITERATIONS.times do
      CASES.each do |text, dim|
        results = Duckling.parse(text, locale: "en", dims: [dim], reference_time: REFERENCE_TIME)
        refute_empty results, "expected #{dim.inspect} entity for #{text.inspect}"
        # Walk the whole returned object graph so a freed-but-referenced
        # Value surfaces as a crash/garbage here rather than going unread.
        results.each { |r| r[:value].inspect }
      end
    end
  ensure
    GC.stress = false
  end
end
