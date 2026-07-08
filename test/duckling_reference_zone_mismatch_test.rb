# frozen_string_literal: true

require_relative "test_helper"

# When both `reference_time:` and `reference_zone:` are given, the fixed
# `utc_offset` carried by `reference_time:` must agree with `reference_zone:`'s
# real UTC offset at that instant. `reference_time:` here is built with a
# fixed -05:00 offset, but "America/Los_Angeles" is at -07:00 (PDT) on
# 2026-06-15 — a caller error, since there's no principled way to silently
# prefer one over the other.
class DucklingReferenceZoneMismatchTest < Minitest::Test
  def test_mismatched_reference_time_offset_and_reference_zone_raises_argument_error
    mismatched_reference_time = Time.new(2026, 6, 15, 12, 0, 0, "-05:00")

    error = assert_raises(ArgumentError) do
      Duckling.parse(
        "now",
        locale: "en",
        dims: ["time"],
        reference_time: mismatched_reference_time,
        reference_zone: "America/Los_Angeles"
      )
    end

    # `Duckling.parse` doesn't restrict kwargs itself, so an unimplemented
    # `reference_zone:` would otherwise flow straight through to
    # `Native.parse`'s strict Magnus binding and get rejected there with its
    # own unrelated ArgumentError ("unknown keyword: :reference_zone") —
    # itself an ArgumentError, so a bare `assert_raises(ArgumentError)` would
    # be satisfied by that impostor without any real offset-mismatch check
    # ever running. Assert on the message to rule that impostor out and pin
    # down the actual semantic complaint we want.
    refute_match(/unknown keyword/i, error.message,
      "expected the offset-mismatch ArgumentError, but got the unrelated " \
      "'unknown keyword' error raised because reference_zone: isn't " \
      "recognized/validated yet: #{error.message.inspect}")
    assert_match(/offset/i, error.message,
      "expected an ArgumentError describing the reference_time:/" \
      "reference_zone: offset mismatch, got: #{error.message.inspect}")
  end
end
