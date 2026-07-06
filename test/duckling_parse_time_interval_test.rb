# frozen_string_literal: true

require "test_helper"

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00, a Tuesday), so relative expressions
# resolve to fixed, assertable values instead of drifting with the real clock.
# See test/duckling_test.rb for the same convention. Guarded with `unless
# defined?` since this file may load in the same process as duckling_test.rb
# (which defines the same top-level constant) via `bundle exec rake test`, or
# standalone via `bin/test test/duckling_time_test.rb`. A real `Time` (not an
# Integer): `Native.parse`'s `reference_time:` requires a `Time`-like value
# (or something responding to `#to_time`) so its `utc_offset` can be threaded
# through to `Naive` results via `Context::timezone()` — an Integer can't
# carry an offset at all.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00") unless defined?(REFERENCE_TIME)

# Extended time-interval corpus, ported from the expression groups covered in
# wafer-inc-duckling's own Rust test corpus (tests/time_corpus.rs) and the
# pyduckling test suite it descends from. Each case asserts the full
# {type: :interval, from: {...}, to: {...}} shape returned by Duckling.parse,
# not just that *an* entity was found.
class DucklingParseTimeIntervalTest < Minitest::Test
  def test_hour_interval_3_4pm
    results = Duckling.parse("3-4pm", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for '3-4pm'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :hour, value[:from][:grain]
    assert_equal Time.new(2013, 2, 12, 15, 0, 0, "-02:00"), value[:from][:value]

    assert_equal :value, value[:to][:type]
    assert_equal :hour, value[:to][:grain]
    # Exclusive hour boundary: "4pm" (16:00) surfaces as 17:00, matching the
    # same convention documented in DucklingIntervalTest for "3pm to 5pm".
    assert_equal Time.new(2013, 2, 12, 17, 0, 0, "-02:00"), value[:to][:value]
  end

  def test_minute_grain_interval_3_30_to_6pm
    results = Duckling.parse("3:30 to 6 PM", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for '3:30 to 6 PM'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :minute, value[:from][:grain]
    assert_equal Time.new(2013, 2, 12, 15, 30, 0, "-02:00"), value[:from][:value]

    assert_equal :value, value[:to][:type]
    # Verified against wafer-inc-duckling's own corpus (tests/time_corpus.rs,
    # test_time_330_to_6_pm): when the interval's finer boundary ("3:30") is
    # minute-grain, the whole interval collapses to minute grain and the
    # exclusive "to" boundary is the named hour plus one *minute* (18:01),
    # not one hour (19:00) as with a pure hour-grain interval like "3-4pm".
    assert_equal :minute, value[:to][:grain]
    assert_equal Time.new(2013, 2, 12, 18, 1, 0, "-02:00"), value[:to][:value]
  end

  def test_date_range_july_13_15
    results = Duckling.parse("July 13-15", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'July 13-15'"

    value = entity[:value]
    assert_equal :value, value[:from][:type]
    assert_equal :day, value[:from][:grain]
    assert_equal Time.new(2013, 7, 13, 0, 0, 0, "-02:00"), value[:from][:value]

    assert_equal :value, value[:to][:type]
    assert_equal :day, value[:to][:grain]
    # Exclusive end-of-range convention (mirrors the hour case): "15" surfaces
    # as the start of the 16th, not midnight of the 15th itself.
    assert_equal Time.new(2013, 7, 16, 0, 0, 0, "-02:00"), value[:to][:value]
  end

  def test_last_2_days
    results = Duckling.parse("last 2 days", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'last 2 days'"

    value = entity[:value]
    assert_equal :day, value[:from][:grain]
    assert_equal :day, value[:to][:grain]
    # Reference date is 2013-02-12; "last 2 days" should span the two days
    # immediately preceding today, i.e. [2013-02-10, 2013-02-12).
    assert_equal Time.new(2013, 2, 10, 0, 0, 0, "-02:00"), value[:from][:value]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), value[:to][:value]
  end

  def test_next_3_days
    results = Duckling.parse("next 3 days", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'next 3 days'"

    value = entity[:value]
    assert_equal :day, value[:from][:grain]
    assert_equal :day, value[:to][:grain]
    # "next 3 days" spans the 3 days immediately following today, starting
    # tomorrow: [2013-02-13, 2013-02-16).
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), value[:from][:value]
    assert_equal Time.new(2013, 2, 16, 0, 0, 0, "-02:00"), value[:to][:value]
  end

  def test_tonight_interval
    results = Duckling.parse("tonight", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'tonight'"

    value = entity[:value]
    assert_equal :hour, value[:from][:grain]
    assert_equal Time.new(2013, 2, 12, 18, 0, 0, "-02:00"), value[:from][:value]
    assert_equal :hour, value[:to][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), value[:to][:value]
  end

  def test_last_night_interval
    results = Duckling.parse("last night", locale: "en", reference_time: REFERENCE_TIME)
    entity = results.find { |r| r[:dim] == :time && r[:value][:type] == :interval }
    refute_nil entity, "expected an interval :time entity for 'last night'"

    value = entity[:value]
    assert_equal :hour, value[:from][:grain]
    assert_equal :hour, value[:to][:grain]
    # Reference is 2013-02-12T04:30; "last night" refers to the evening of
    # the 11th, spanning [2013-02-11T18:00, 2013-02-12T00:00).
    assert_equal Time.new(2013, 2, 11, 18, 0, 0, "-02:00"), value[:from][:value]
    assert_equal Time.new(2013, 2, 12, 0, 0, 0, "-02:00"), value[:to][:value]
  end
end

# Empirically verified (2026-07-02) against the real ext/duckling/src/lib.rs
# binding before writing any assertions below — do not trust the summary in
# this comment blindly if the Rust source changes; re-verify.
#
# `with_latent:` IS a recognized, plumbed-through keyword arg (ext/duckling/
# src/lib.rs's `get_kwargs` call lists "with_latent" among the optional
# keywords at line 43, defaults to `false` at line 50, and is threaded into
# `duckling::Options { with_latent }` at line 55 — passed straight to the
# wrapped `duckling::parse`). Passing `with_latent: true` or `with_latent:
# false` does NOT raise ArgumentError. Every observed result Hash also
# carries a `:latent` boolean key (set at lib.rs line 277-279 whenever
# `entity.latent` is `Some(_)`, which every entity observed here has).
#
# What actually flips behavior: "at 3" (a bare hour with no am/pm) — the
# case this file's spec assumed would be the classic latent example — is
# NOT gated by `with_latent` at all in practice: it comes back identically
# (one result, `latent: false`) whether `with_latent:` is omitted, false, or
# true. The construct that IS gated is a bare part-of-day term like
# "morning" or "afternoon": with `with_latent:` omitted or `false`, it
# returns `[]` (filtered out entirely); with `with_latent: true`, it returns
# one entity with `latent: true`. Unambiguous times ("3pm", "tonight")
# always come back with `latent: false` regardless of the flag.
class DucklingParseLatentTest < Minitest::Test
  def test_with_latent_kwarg_is_accepted_without_raising
    # Pins that this is a real, recognized kwarg (not a design-doc
    # assumption) — passing it in either direction must not raise.
    Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)
    Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
  end

  def test_results_carry_a_latent_boolean_field
    results = Duckling.parse("3pm", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)
    refute_empty results
    entity = results.first
    assert entity.key?(:latent), "expected result Hash to carry a :latent key"
    assert_includes [true, false], entity[:latent]
  end

  def test_with_latent_true_surfaces_part_of_day_terms_hidden_by_default
    # "morning" is the case that's actually gated: absent/false, duckling
    # withholds it entirely; true reveals it, flagged latent: true.
    without_latent_default = Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME)
    without_latent_explicit = Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
    with_latent = Duckling.parse("morning", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)

    assert_empty without_latent_default, "expected 'morning' to be withheld when with_latent is omitted"
    assert_empty without_latent_explicit, "expected 'morning' to be withheld when with_latent: false"

    assert_equal 1, with_latent.size, "expected 'morning' to surface exactly one entity when with_latent: true"
    entity = with_latent.first
    assert_equal "morning", entity[:body]
    assert_equal :time, entity[:dim]
    assert_equal true, entity[:latent], "expected the surfaced 'morning' entity to be flagged latent: true"
  end

  def test_bare_hour_is_not_gated_by_with_latent
    # Characterizes a surprising finding: "at 3" (bare hour, no am/pm) is the
    # textbook duckling latent-time example, but in THIS binding it is
    # returned identically regardless of with_latent — it is never withheld
    # and never flagged latent: true. So "with_latent" here specifically
    # gates part-of-day terms (see test above), not bare-hour ambiguity.
    without_kwarg = Duckling.parse("at 3", locale: "en", reference_time: REFERENCE_TIME)
    with_false = Duckling.parse("at 3", locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
    with_true = Duckling.parse("at 3", locale: "en", reference_time: REFERENCE_TIME, with_latent: true)

    [without_kwarg, with_false, with_true].each do |results|
      assert_equal 1, results.size, "expected 'at 3' to always surface exactly one entity"
      assert_equal false, results.first[:latent], "expected 'at 3' to never be flagged latent: true"
    end

    assert_equal without_kwarg.first[:value], with_true.first[:value],
      "expected 'at 3' to resolve identically regardless of with_latent"
  end

  def test_unambiguous_times_are_never_latent_regardless_of_flag
    %w[3pm tonight].each do |text|
      with_false = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME, with_latent: false)
      with_true = Duckling.parse(text, locale: "en", reference_time: REFERENCE_TIME, with_latent: true)

      refute_empty with_false, "expected #{text.inspect} to parse with with_latent: false"
      refute_empty with_true, "expected #{text.inspect} to parse with with_latent: true"
      assert_equal false, with_false.first[:latent]
      assert_equal false, with_true.first[:latent]
    end
  end
end

# Empirically verified behavior (ruby -e against the compiled extension,
# ext/duckling/src/lib.rs `parse_locale`, and README's "Keyword arguments"
# section) before writing these assertions:
#
#   locale: "en"          -> parses normally, no error
#   locale: "xx"           -> raises ArgumentError: 'unsupported locale: "xx"'
#   locale: omitted entirely -> defaults to "en" silently (no ArgumentError for
#                                a missing keyword — `locale` is an optional kwarg
#                                in the Magnus binding, defaulting to "en")
class DucklingParseLocaleTest < Minitest::Test
  def test_valid_locale_en_parses_tomorrow
    results = Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME)

    refute_empty results, "Expected a non-empty result for 'tomorrow' with locale: \"en\""
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow'"
    assert_equal :day, time_entity[:value][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), time_entity[:value][:value]
  end

  def test_invalid_locale_raises_argument_error
    error = assert_raises(ArgumentError) do
      Duckling.parse("tomorrow", locale: "xx", reference_time: REFERENCE_TIME)
    end
    assert_match(/unsupported locale/i, error.message)
    assert_match(/xx/, error.message)
  end

  def test_locale_with_unsupported_region_raises_argument_error
    error = assert_raises(ArgumentError) do
      Duckling.parse("tomorrow", locale: "en-ZZ", reference_time: REFERENCE_TIME)
    end
    assert_match(/unsupported locale/i, error.message)
    assert_match(/en-ZZ/, error.message)
  end

  def test_omitted_locale_defaults_to_en_without_raising
    results = Duckling.parse("tomorrow", reference_time: REFERENCE_TIME)

    refute_empty results, "Expected omitted locale: to default to \"en\" and parse normally"
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result when locale: is omitted"
    assert_equal :day, time_entity[:value][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), time_entity[:value][:value]
  end

  def test_valid_region_qualified_locale_parses_normally
    results = Duckling.parse("tomorrow", locale: "en-GB", reference_time: REFERENCE_TIME)

    refute_empty results, "Expected a non-empty result for 'tomorrow' with locale: \"en-GB\""
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow' with locale: \"en-GB\""
    assert_equal :day, time_entity[:value][:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), time_entity[:value][:value]
  end
end
