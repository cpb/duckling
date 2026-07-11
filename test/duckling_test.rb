# frozen_string_literal: true

require "test_helper"
require "date"

VALID_GRAINS = %i[second minute hour day week month quarter year].freeze

class DucklingTest < Minitest::Test
  # Anchor for the America/New_York DST tests: 2026-03-01 09:00 EST, ahead of
  # the 2026-03-08 spring-forward. Its fixed -05:00 offset agrees with the
  # zone's real offset at that instant, which the offset-mismatch check
  # requires — every test that pairs a reference_time: with
  # reference_zone: "America/New_York" must use an anchor like this or it
  # trips that ArgumentError instead of exercising its own assertion.
  EST_REFERENCE_TIME = Time.new(2026, 3, 1, 9, 0, 0, "-05:00")

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

  # `reference_zone:` makes a `:Naive`
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
    reference_time = EST_REFERENCE_TIME
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
  # occurs. There's no benefit to raising over it just because this is a
  # primary value the caller literally named rather than a generated
  # recurrence entry — it resolves the same deterministic way either kind
  # does (see test_reference_zone_resolves_recurrence_gap_entry_deterministically
  # and local_time_in_zone): shifted forward past the gap to 3:30 EDT.
  def test_reference_zone_resolves_primary_gap_deterministically
    reference_time = EST_REFERENCE_TIME

    entity = entity_for("March 8 2026 2:30am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    resolved = single_point(entity)[:value]

    assert_equal 3, resolved.hour,
      "expected the skipped 2:30 wall clock to shift forward past the gap to 3:30, got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal(-14400, resolved.utc_offset,
      "expected the spring-forward gap primary value to take the post-transition offset (EDT, -14400), got #{resolved.inspect}")
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
    reference_time = EST_REFERENCE_TIME
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
    reference_time = EST_REFERENCE_TIME
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
    # Pin the specific complaint: the Rust side's resolve_naive failure is also
    # an ArgumentError that contains the word "offset" ("invalid or ambiguous
    # naive time for reference offset"), so a bare /offset/ match wouldn't rule
    # that impostor out.
    assert_match(/does not match reference_zone/, error.message,
      "expected an ArgumentError describing the reference_time:/" \
      "reference_zone: offset mismatch, got: #{error.message.inspect}")
  end

  # Characterizes apply_reference_zone's loud-failure behavior when a :time
  # entity's :value doesn't match the known Single/Interval shape — a future
  # drift in the Rust side's serialized shape must not pass unnoticed. Asserts
  # the named Duckling::ShapeError specifically (not bare RuntimeError, which
  # the native-panic path also raises) so an unrelated RuntimeError can't
  # satisfy it.
  def test_reference_zone_raises_on_unrecognized_time_value_shape
    malformed_entity = {dim: :time, value: {Time: {NotARealTag: {}}}}

    assert_raises(Duckling::ShapeError) do
      Duckling.apply_reference_zone([malformed_entity], "America/New_York")
    end
  end

  # Companion to the above, one layer deeper: a TimePoint tagged neither :Naive
  # nor :Instant must also fail loudly, so serde drift at the point layer can't
  # slip a result through resolved against the wrong offset.
  def test_reference_zone_raises_on_unrecognized_time_point_shape
    malformed_entity = {dim: :time, value: {Time: {Single: {value: {NotARealTag: {}}}}}}

    assert_raises(Duckling::ShapeError) do
      Duckling.apply_reference_zone([malformed_entity], "America/New_York")
    end
  end

  # A Single's `values` recurrence array — populated on essentially
  # every parse, not only explicit recurrences — is reinterpreted per entry, so
  # each occurrence picks up its own date's DST offset. "every monday at 3am"
  # anchored 2026-03-01 yields two Mondays straddling the 03-08 transition: the
  # earlier must resolve to EST (-18000), the later to EDT (-14400), wall clock
  # preserved.
  def test_reference_zone_resolves_single_values_across_dst_transition
    reference_time = EST_REFERENCE_TIME
    entity = entity_for("every monday at 3am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    resolved = entity[:value][:Time][:Single][:values].map { |p| time_point(p)[:value] }
    before = resolved.find { |t| t.day == 2 }
    after = resolved.find { |t| t.day == 9 }

    assert_equal 3, before.hour, "expected the 3am wall clock preserved, got #{before.inspect}"
    assert_equal(-18000, before.utc_offset,
      "expected the pre-transition recurrence entry (March 2) to resolve to EST (-18000), got #{before.inspect}")
    assert_equal 3, after.hour, "expected the 3am wall clock preserved, got #{after.inspect}"
    assert_equal(-14400, after.utc_offset,
      "expected the post-transition recurrence entry (March 9) to resolve to EDT (-14400), got #{after.inspect}")
  end

  # An Interval's `values` endpoint pairs are reinterpreted the same
  # way, each leg independently. "from March 7th 3:00am to March 9th 3:00am"
  # anchored 2026-03-01 produces a values entry straddling the 03-08
  # transition: its `from` (March 7) must resolve to EST (-18000) and its `to`
  # (March 9) to EDT (-14400).
  def test_reference_zone_resolves_interval_values_endpoints_independently
    reference_time = EST_REFERENCE_TIME
    entity = entity_for("from March 7th 2026 3:00am to March 9th 2026 3:00am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    endpoints = entity[:value][:Time][:Interval][:values].first
    from = time_point(endpoints[:from])[:value]
    to = time_point(endpoints[:to])[:value]

    assert_equal(-18000, from.utc_offset,
      "expected the values entry `from` leg (March 7, pre-transition) to resolve to EST (-18000), got #{from.inspect}")
    assert_equal(-14400, to.utc_offset,
      "expected the values entry `to` leg (March 9, post-transition) to resolve to EDT (-14400), got #{to.inspect}")
  end

  # A DST gap in a *generated* recurrence entry resolves the same
  # deterministic way a primary value does
  # (test_reference_zone_resolves_primary_gap_deterministically) — no
  # ArgumentError either way, so one collateral bad occurrence can't destroy
  # the whole result. "every sunday at 2:30am" anchored 2026-02-28 generates 2026-03-08 02:30,
  # which the spring-forward gap skips; that entry resolves deterministically by
  # shifting forward past the gap to 03:30 EDT, and the call as a whole returns
  # normally. Shifting forward (rather than keeping the 2:30 wall clock and
  # stamping EDT on it) is what ActiveSupport::TimeZone#parse/#local do with the
  # same input, and is the only resolution whose instant and rendered local time
  # agree — see local_time_in_zone.
  def test_reference_zone_resolves_recurrence_gap_entry_deterministically
    reference_time = Time.new(2026, 2, 28, 9, 0, 0, "-05:00")
    entity = entity_for("every sunday at 2:30am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    gap_entry = entity[:value][:Time][:Single][:values]
      .map { |p| time_point(p)[:value] }
      .find { |t| t.month == 3 && t.day == 8 }

    refute_nil gap_entry, "expected a 2026-03-08 recurrence entry"
    assert_equal 3, gap_entry.hour,
      "expected the skipped 2:30 wall clock to shift forward past the gap to 3:30, got #{gap_entry.inspect}"
    assert_equal 30, gap_entry.min
    assert_equal(-14400, gap_entry.utc_offset,
      "expected the spring-forward gap recurrence entry to take the post-transition offset (EDT, -14400), got #{gap_entry.inspect}")

    # The bug this guards against: 2:30 -04:00 is 06:30Z, and New York is still
    # on EST at 06:30Z, so that Time would carry an offset the zone doesn't
    # observe at its own instant. Assert the offset is the real one for this
    # instant, which .hour and .utc_offset alone can't catch (they'd both pass
    # on 2:30 -04:00 if .hour were 2).
    real_offset = TZInfo::Timezone.get("America/New_York").period_for(gap_entry).observed_utc_offset
    assert_equal real_offset, gap_entry.utc_offset,
      "expected the resolved Time's utc_offset to be the offset America/New_York actually " \
      "observes at that instant, got #{gap_entry.inspect} (real offset #{real_offset})"
  end

  # A gap shifts forward by the transition's own width, not by a hardcoded
  # hour. Australia/Lord_Howe springs forward only 30 minutes (02:00 → 02:30 on
  # 2026-10-04), so a skipped 02:15 resolves to 02:45 — where ActiveSupport's
  # `@time += 1.hour` retry would overshoot to 03:15. Exercises
  # local_time_in_zone directly: no English time expression reliably generates a
  # Lord Howe recurrence entry landing in that 30-minute window.
  def test_reference_zone_gap_shifts_by_transition_width_not_a_hardcoded_hour
    zone = TZInfo::Timezone.get("Australia/Lord_Howe")
    skipped = Time.new(2026, 10, 4, 2, 15, 0, "+10:30")

    resolved = Duckling.send(:local_time_in_zone, zone, skipped)

    assert_equal 2, resolved.hour, "expected a 30-minute shift to 02:45, got #{resolved.inspect}"
    assert_equal 45, resolved.min, "expected a 30-minute shift to 02:45, got #{resolved.inspect}"
    assert_equal zone.period_for(resolved).observed_utc_offset, resolved.utc_offset,
      "expected the resolved Time to carry the offset Lord Howe observes at its own instant"
  end

  # A gap late in the local day has a transition instant past the *next* UTC
  # midnight when the zone's offset is negative — America/Nuuk springs forward
  # at 23:00 local while at UTC-2, putting the transition at 01:00 UTC the
  # following day. gap_delta's scan window must therefore center on the
  # skipped wall clock itself; anchoring it to the UTC midnight of the wall
  # clock's date excluded such transitions, and the resulting nil made
  # gap_delta crash with NoMethodError instead of resolving the gap.
  def test_reference_zone_resolves_gap_late_in_local_day
    reference_time = Time.new(2026, 3, 28, 12, 0, 0, "-02:00")
    entity = entity_for("March 28 2026 11:30pm", :time,
      reference_time: reference_time, reference_zone: "America/Nuuk")
    resolved = single_point(entity)[:value]

    assert_equal 0, resolved.hour,
      "expected the skipped 23:30 wall clock to shift forward past the gap to 00:30, got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal 29, resolved.day, "expected the shift to land on the next day, got #{resolved.inspect}"
    assert_equal(-3600, resolved.utc_offset,
      "expected the post-transition offset (UTC-1, -3600), got #{resolved.inspect}")
  end

  # The fall-back "first occurrence" is selected by position (periods.first in
  # local_time_in_zone), not by tzinfo's dst flag: dst=true only means
  # pre-transition where the earlier period observes DST, and negative-DST
  # zones invert that — tzinfo models Europe/Dublin's winter GMT as its
  # dst?==true period, so flag-based resolution there returns the
  # post-transition occurrence, an hour off as an instant. Dublin's 2026-10-25
  # fall-back makes 01:30 ambiguous; the first occurrence is IST (+3600).
  def test_reference_zone_overlap_takes_first_occurrence_in_negative_dst_zones
    reference_time = Time.new(2026, 9, 1, 12, 0, 0, "+01:00")
    entity = entity_for("October 25 2026 1:30am", :time,
      reference_time: reference_time, reference_zone: "Europe/Dublin")
    resolved = single_point(entity)[:value]

    assert_equal 1, resolved.hour, "expected the 1:30 wall clock preserved through the overlap, got #{resolved.inspect}"
    assert_equal 30, resolved.min
    assert_equal 3600, resolved.utc_offset,
      "expected the first (pre-transition) occurrence (IST, +3600), got #{resolved.inspect}"
  end

  # Fall-back side: an ambiguous recurrence entry resolves to its
  # first (pre-transition) occurrence rather than raising. "every sunday at
  # 1:30am" anchored 2026-10-22 generates 2026-11-01 01:30, which the fall-back
  # overlap makes ambiguous; it resolves to the first occurrence (EDT, -14400).
  def test_reference_zone_resolves_recurrence_overlap_entry_deterministically
    reference_time = Time.new(2026, 10, 22, 9, 0, 0, "-04:00")
    entity = entity_for("every sunday at 1:30am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    overlap_entry = entity[:value][:Time][:Single][:values]
      .map { |p| time_point(p)[:value] }
      .find { |t| t.month == 11 && t.day == 1 }

    refute_nil overlap_entry, "expected a 2026-11-01 recurrence entry"
    assert_equal 1, overlap_entry.hour, "expected the 1:30 wall clock preserved through the overlap, got #{overlap_entry.inspect}"
    assert_equal(-14400, overlap_entry.utc_offset,
      "expected the fall-back overlap recurrence entry to take the first (pre-transition) occurrence (EDT, -14400), got #{overlap_entry.inspect}")
  end

  # Primary-value counterpart to test_reference_zone_resolves_recurrence_overlap_entry_deterministically:
  # a caller-named wall clock that a fall-back overlap makes ambiguous resolves
  # to its first (pre-transition) occurrence too, same as a recurrence entry —
  # no ArgumentError either way.
  def test_reference_zone_resolves_primary_overlap_deterministically
    reference_time = Time.new(2026, 10, 22, 9, 0, 0, "-04:00")
    entity = entity_for("November 1st 2026 1:30am", :time,
      reference_time: reference_time, reference_zone: "America/New_York")
    resolved = single_point(entity)[:value]

    assert_equal 1, resolved.hour, "expected the 1:30 wall clock preserved through the overlap, got #{resolved.inspect}"
    assert_equal(-14400, resolved.utc_offset,
      "expected the fall-back overlap primary value to take the first (pre-transition) occurrence (EDT, -14400), got #{resolved.inspect}")
  end

  # reference_zone: given WITHOUT reference_time: still reinterprets Naive
  # result offsets against the zone — it is not a no-op when the anchor is
  # absent. An absolute date expression ("March 7th 2026 3:00am") is used so
  # the result's wall-clock value doesn't depend on any anchor: the native
  # crate resolves it the same way regardless of reference_time:. Without
  # reference_zone: the offset defaults to +00:00 (the native crate's
  # FixedOffset when no reference_time: is given); with reference_zone: it
  # must be the zone's real offset for that date (EST, -18000).
  #
  # This does NOT test the "does not anchor the parse" edge: a relative
  # expression like "tomorrow" anchors on the machine-local clock, not on
  # "now in that zone", so Duckling.parse("tomorrow", reference_zone:
  # "Asia/Tokyo") on a US host can land on the wrong calendar day. That
  # behavior is documented in the comment block above Duckling.parse and in
  # AGENTS.md, but can't be pinned by a test without controlling the host
  # timezone — the offset reinterpretation below is the testable part.
  def test_reference_zone_without_reference_time_reinterprets_offsets
    entity = entity_for("March 7th 2026 3:00am", :time, reference_zone: "America/New_York")
    resolved = single_point(entity)[:value]

    assert_equal 3, resolved.hour, "expected the 3am wall clock preserved, got #{resolved.inspect}"
    assert_equal(-18000, resolved.utc_offset,
      "expected reference_zone: to resolve the Naive offset against America/New_York " \
      "(EST, -18000) even without reference_time:, got #{resolved.inspect}")
  end
end
