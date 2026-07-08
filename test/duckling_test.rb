# frozen_string_literal: true

require "test_helper"
require "date"

VALID_GRAINS = %i[second minute hour day week month quarter year].freeze

class DucklingTest < Minitest::Test
  def test_parse_returns_array
    assert_kind_of Array, Duckling.parse("tomorrow", locale: "en")
  end

  def test_parse_result_shape
    results = Duckling.parse("at 3pm", locale: "en", reference_time: REFERENCE_TIME)
    assert results.size > 0, "Expected at least one result from Duckling.parse"
    first = results.first
    assert first.key?(:body), "Expected result to have :body key"
    assert first.key?(:start), "Expected result to have :start key"
    assert first.key?(:end), "Expected result to have :end key"
    assert first.key?(:dim), "Expected result to have :dim key"
    assert first.key?(:value), "Expected result to have :value key"
    value = first[:value]
    assert_kind_of Hash, value, "Expected :value to be a Hash"
    assert value.key?(:Time), "Expected :value to be tagged :Time"
    single = value[:Time][:Single]
    refute_nil single, "Expected :value to be tagged :Single, got: #{value.inspect}"
    point = time_point(single[:value])
    assert_equal "at 3pm", first[:body]
    assert_equal :hour, point[:grain]
    assert_kind_of Time, point[:value]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), point[:value]
  end

  def test_parses_time_dimension
    results = Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow'"
    point = time_point(time_entity[:value][:Time][:Single][:value])
    assert_includes VALID_GRAINS, point[:grain],
      "Expected grain to be one of #{VALID_GRAINS.inspect}"
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_parity_with_wafer_inc_duckling
    results = Duckling.parse("Call me tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    assert_operator results.size, :>=, 1, "expected at least one entity for 'Call me tomorrow'"
    entity = results.find { |r| r[:body] == "tomorrow" }
    refute_nil entity, "expected an entity with body: 'tomorrow'"
    assert_equal :time, entity[:dim]
    single = entity[:value][:Time][:Single]
    point = time_point(single[:value])
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
    assert_kind_of Array, single[:values]
    assert single[:values].size > 0, "expected :values to be a non-empty Array"
  end

  def test_parses_interval
    results = Duckling.parse("from 3pm to 5pm", locale: "en", reference_time: REFERENCE_TIME)
    assert results.size > 0
    entity = results.first
    assert_equal :time, entity[:dim]
    interval = entity[:value][:Time][:Interval]
    refute_nil interval, "Expected :value to be tagged :Interval, got: #{entity[:value].inspect}"
    assert interval.key?(:from), "interval value should have :from"
    assert interval.key?(:to), "interval value should have :to"
    from = time_point(interval[:from])
    assert_equal :hour, from[:grain]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), from[:value]
    to = time_point(interval[:to])
    assert_equal :hour, to[:grain]
    # duckling represents interval :to as the exclusive hour boundary, not the
    # literal named time — "5pm" (17:00) surfaces as 18:00. Verified against
    # wafer-inc-duckling's own tests/time_corpus.rs (e.g. "3-4pm" -> to 17:00).
    assert_equal Time.new(2013, 2, 12, 18, 0, 0, "-02:00"), to[:value]
  end

  def test_time_reference_time_preserves_utc_offset_for_instant_results
    results = Duckling.parse("in one hour", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'in one hour'"
    point = time_point(entity[:value][:Time][:Single][:value])
    assert_kind_of Time, point[:value]
    assert_equal REFERENCE_TIME + 3600, point[:value]
    # Time#== only compares the instant, not utc_offset — assert this
    # explicitly since preserving the offset is the whole point of this test.
    assert_equal(-7200, point[:value].utc_offset)
  end

  def test_non_time_reference_time_raises_type_error
    assert_raises(TypeError) do
      Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME.to_i)
    end
  end

  def test_date_time_reference_time_is_coerced_and_preserves_utc_offset
    reference_time = DateTime.new(2013, 2, 12, 4, 30, 0, "-02:00")
    results = Duckling.parse("in one hour", locale: "en", reference_time: reference_time)
    entity = results.find { |r| r[:dim] == :time }
    refute_nil entity, "Expected a :time dimension result for 'in one hour'"
    point = time_point(entity[:value][:Time][:Single][:value])
    assert_kind_of Time, point[:value]
    assert_equal REFERENCE_TIME + 3600, point[:value]
    assert_equal(-7200, point[:value].utc_offset)
  end

  # Issue #85 (re-implemented for #96): `reference_zone:` makes a `:Naive`
  # (wall-clock) time result DST-aware by resolving its UTC offset against the
  # real IANA zone for *that result's own date*, instead of the single fixed
  # offset `reference_time:` provides today. US DST began 2026-03-08 02:00
  # local (America/New_York): "spring forward" from EST (UTC-5) to EDT (UTC-4).
  # A naive result dated just before that transition must resolve to -18000
  # (EST); one dated just after must resolve to -14400 (EDT) — proving each
  # result is resolved against its own date, not a single offset applied
  # uniformly across both.
  def test_reference_zone_resolves_naive_offset_per_date_across_dst_transition
    # America/New_York's real UTC offset at this instant (2026-03-01, before
    # the 03-08 spring-forward) is -18000 (EST) — matching the fixed offset
    # reference_time: carries, so this doesn't trip the offset-mismatch check
    # covered by test_reference_zone_mismatched_reference_time_offset_raises_argument_error.
    reference_time = Time.new(2026, 3, 1, 9, 0, 0, "-05:00")
    before_entity = entity_for("March 7th 2026 3:00am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    after_entity = entity_for("March 9th 2026 3:00am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")

    before_value = single_point(before_entity)[:value]
    after_value = single_point(after_entity)[:value]

    assert_equal 3, before_value.hour,
      "expected the wall-clock hour (3am) to be preserved, got #{before_value.inspect}"
    assert_equal(-18000, before_value.utc_offset,
      "Expected 'March 7th 2026' (before the 2026-03-08 America/New_York DST transition) " \
      "to resolve to EST (UTC-5, -18000s) when reference_zone: is given, got #{before_value.utc_offset}")
    assert_equal 3, after_value.hour,
      "expected the wall-clock hour (3am) to be preserved, got #{after_value.inspect}"
    assert_equal(-14400, after_value.utc_offset,
      "Expected 'March 9th 2026' (after the 2026-03-08 America/New_York DST transition) " \
      "to resolve to EDT (UTC-4, -14400s) when reference_zone: is given, got #{after_value.utc_offset}")
  end

  # America/New_York springs forward from 2:00am straight to 3:00am on
  # 2026-03-08, so "2:30am" that day is a local time that never actually
  # occurs — it must raise rather than silently pick an arbitrary (wrong)
  # offset.
  def test_reference_zone_raises_argument_error_for_dst_spring_forward_gap
    reference_time = Time.new(2026, 3, 1, 9, 0, 0, "-05:00")

    error = assert_raises(ArgumentError) do
      Duckling.parse(
        "March 8 2026 2:30am",
        locale: "en",
        dims: ["time"],
        reference_time: reference_time,
        reference_zone: "America/New_York"
      )
    end

    # Since reference_zone: is currently stripped before reaching
    # Native.parse (lib/duckling.rb), any unrelated ArgumentError elsewhere
    # in the call path would otherwise also satisfy a bare assert_raises here
    # — see test_reference_zone_mismatched_reference_time_offset_raises_argument_error
    # for the same impostor concern. Pin down the actual gap complaint.
    refute_match(/unknown keyword/i, error.message,
      "expected the DST-gap ArgumentError, but got the unrelated 'unknown " \
      "keyword' error raised because reference_zone: isn't recognized/" \
      "validated yet: #{error.message.inspect}")
    assert_match(/gap|nonexistent|does not exist|spring.forward/i, error.message,
      "expected an ArgumentError describing the DST spring-forward gap, got: #{error.message.inspect}")
  end

  # TimePoint::Instant results (e.g. "in 3 hours" — relative/duration-based,
  # already resolved to an absolute instant by the underlying Rust crate
  # against a single FixedOffset before this gem ever sees it) must NOT be
  # reinterpreted by reference_zone:. That arithmetic imprecision is
  # explicitly out of scope (tracked separately in issue #83) —
  # reference_zone:'s DST awareness only applies to :Naive (wall-clock)
  # results.
  def test_reference_zone_leaves_instant_result_unaffected
    # See test_reference_zone_resolves_naive_offset_per_date_across_dst_transition
    # for why reference_time: must itself agree with America/New_York's real
    # offset at this instant, rather than reusing REFERENCE_TIME's -02:00.
    reference_time = Time.new(2026, 3, 1, 9, 0, 0, "-05:00")
    without_zone = entity_for("in 3 hours", :time, reference_time: reference_time)
    with_zone = entity_for("in 3 hours", :time,
      reference_time: reference_time, reference_zone: "America/New_York")

    instant_without = single_point(without_zone)[:value]
    instant_with = single_point(with_zone)[:value]

    assert_equal instant_without, instant_with,
      "expected reference_zone: to leave a TimePoint::Instant result's resolved Time completely unaffected"
    assert_equal instant_without.utc_offset, instant_with.utc_offset,
      "expected reference_zone: to leave a TimePoint::Instant result's utc_offset completely " \
      "unaffected (Time#== only compares the instant, not utc_offset, so this needs its own assertion)"
  end

  # Split from test_reference_zone_leaves_instant_result_unaffected so a
  # failure here isn't masked under, or misattributed to, that test's
  # differently-named primary assertion.
  def test_reference_zone_rejects_unrecognized_zone_name
    assert_raises(ArgumentError) do
      Duckling.parse(
        "in 3 hours",
        locale: "en",
        dims: ["time"],
        reference_time: REFERENCE_TIME,
        reference_zone: "Not/A/Real/Zone"
      )
    end
  end

  # An Interval-shaped time result's `from` and `to` legs must each be
  # reinterpreted against `reference_zone:` INDEPENDENTLY, using each leg's
  # own date's real UTC offset — not a single offset borrowed from
  # reference_time: or from just one of the two legs. "from March 7th 2026
  # 3:00am to March 9th 2026 3:00am" straddles the US spring-forward
  # transition at 2:00am local on 2026-03-08: the `from` leg (March 7, still
  # standard time) must resolve to EST (UTC-5) while the `to` leg (March 9,
  # already daylight time) must resolve to EDT (UTC-4).
  def test_reference_zone_resolves_interval_legs_independently_across_dst_transition
    # See test_reference_zone_resolves_naive_offset_per_date_across_dst_transition
    # for why reference_time: must itself agree with America/New_York's real
    # offset at this instant, rather than reusing REFERENCE_TIME's -02:00.
    reference_time = Time.new(2026, 3, 1, 9, 0, 0, "-05:00")
    entity = entity_for("from March 7th 2026 3:00am to March 9th 2026 3:00am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    from_point, to_point = interval_points(entity)

    assert_equal 3, from_point[:value].hour,
      "expected the `from` leg's wall-clock hour (3am) to be preserved, got #{from_point[:value].inspect}"
    assert_equal(-18000, from_point[:value].utc_offset,
      "expected the `from` leg (March 7, before the spring-forward " \
      "transition) to resolve to America/New_York's EST offset (-18000), " \
      "got #{from_point[:value].utc_offset} (#{from_point[:value].inspect})")

    assert_equal 3, to_point[:value].hour,
      "expected the `to` leg's wall-clock hour (3am) to be preserved, got #{to_point[:value].inspect}"
    assert_equal(-14400, to_point[:value].utc_offset,
      "expected the `to` leg (March 9, after the spring-forward " \
      "transition) to resolve to America/New_York's EDT offset (-14400), " \
      "got #{to_point[:value].utc_offset} (#{to_point[:value].inspect})")
  end

  # When both `reference_time:` and `reference_zone:` are given, the fixed
  # `utc_offset` carried by `reference_time:` must agree with
  # `reference_zone:`'s real UTC offset at that instant. `reference_time:`
  # here is built with a fixed -05:00 offset, but "America/Los_Angeles" is at
  # -07:00 (PDT) on 2026-06-15 — a caller error, since there's no principled
  # way to silently prefer one over the other.
  def test_reference_zone_mismatched_reference_time_offset_raises_argument_error
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

  # Characterizes apply_reference_zone's loud-failure behavior when a :time
  # entity's :value doesn't match the known Single/Interval shape — a future
  # drift in the Rust side's serialized shape must not pass unnoticed.
  def test_reference_zone_raises_on_unrecognized_time_value_shape
    malformed_entity = {dim: :time, value: {Time: {NotARealTag: {}}}}

    assert_raises(RuntimeError) do
      Duckling.apply_reference_zone([malformed_entity], "America/New_York")
    end
  end
end
