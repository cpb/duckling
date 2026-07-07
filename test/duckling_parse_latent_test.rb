# frozen_string_literal: true

require "test_helper"

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
