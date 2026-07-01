# frozen_string_literal: true

require "test_helper"

# Characterizes a known upstream limitation: a bare, comma-separated run of
# <time> expressions with nothing else between them collapses into a single
# Entity instead of one per date, and every date after the first is silently
# dropped from the result — not deprioritized as latent, not truncated with a
# warning, just absent.
#
# Root cause (confirmed by reading wafer-inc-duckling's source, not guessed):
#
# 1. `src/dimensions/time/en.rs` has a compose rule matching
#    `<time> "of"/"from"/"for"/","/"'s" <time>` — a bare comma between two
#    time expressions is valid grammar for composing them into one (this is
#    what makes "March 1st, 2013" or "Monday, March 1st" parse correctly).
#    The rule is greedy and recursive, so a chain like "March 3, March 9,
#    April 12, May 5" matches as one long composite span in addition to each
#    date matching individually.
# 2. `src/ranking/mod.rs`'s `remove_overlapping` then keeps only the longest
#    span when candidates overlap, discarding the shorter individual date
#    matches nested inside it — mirroring the original Haskell duckling's
#    "longest/most-specific interpretation wins" ranking design.
#
# This is not a shortcut in this gem's Magnus binding: ext/duckling/src/lib.rs
# performs no deduplication or filtering of its own — it returns exactly the
# Vec<Entity> that duckling::parse() produces. There is also no parse() option
# (dims/context/Options) to disable the compose rule or request overlapping
# candidates back, so this cannot be worked around from the Ruby layer today.
#
# Practical takeaway: whether a comma-joined list of dates parses correctly
# depends on whether *every* date has some non-time token immediately before
# its comma (a name, "then", a colon, filler words). A single bare
# comma-to-comma run of dates anywhere in the string collapses that run into
# one entity. See DucklingCommaListKnownLimitationTest below for the specific
# shapes that fail, including one case where the surviving :value isn't even
# reliably the leftmost date in the collapsed run.
COMMA_LIST_REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i

class DucklingCommaListReliableTest < Minitest::Test
  def extracted_dates(text)
    Duckling.parse(text, locale: "en", reference_time: COMMA_LIST_REFERENCE_TIME)
      .select { |r| r[:dim] == :time }
      .map { |r| r[:value][:value] }
  end

  def test_dates_each_prefixed_by_a_name_extract_individually
    text = "Emma: March 3, Liam: March 9, Noah: April 12, Ava: May 5"
    assert_equal(
      ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"],
      extracted_dates(text)
    )
  end

  def test_dates_joined_with_and_extract_individually
    text = "March 3 and March 9 and April 12 and May 5"
    assert_equal(
      ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"],
      extracted_dates(text)
    )
  end

  def test_dates_separated_by_periods_extract_individually
    text = "March 3. March 9. April 12. May 5."
    assert_equal(
      ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"],
      extracted_dates(text)
    )
  end
end

class DucklingCommaListKnownLimitationTest < Minitest::Test
  # See the file-level comment above for the root-cause trace. Each shape below
  # is documented by a *pair* of tests:
  #
  #   - `test_current_actual_*` — passing, pins today's real (wrong) output.
  #     If wafer-inc-duckling's grammar or ranking ever changes, this test
  #     starts failing, which is the signal to revisit the paired skip below.
  #   - `test_*` (skipped) — asserts the *correct* extraction (four distinct
  #     dates) we actually want. Skipped so it doesn't break CI. Delete the
  #     `skip` line once the current-actual test above starts failing, to
  #     confirm the fix and re-enable the real assertion.

  def extracted_dates(text)
    Duckling.parse(text, locale: "en", reference_time: COMMA_LIST_REFERENCE_TIME)
      .select { |r| r[:dim] == :time }
      .map { |r| r[:value][:value] }
  end

  def test_current_actual_extraction_for_bare_comma_separated_dates
    # The trailing "and may 5" isn't part of the comma chain, so it survives
    # as its own entity; the three comma-joined dates before it collapse into
    # one, keeping only the first (March 3).
    text = "birthdays are march 3, march 9, april 12 and may 5"
    assert_equal(["2013-03-03T00:00:00", "2013-05-05T00:00:00"], extracted_dates(text))
  end

  def test_bare_comma_separated_dates_collapse_into_one_entity
    skip "known upstream limitation: bare comma-to-comma date runs collapse into one Entity (see file comment)"

    text = "birthdays are march 3, march 9, april 12 and may 5"
    assert_equal(
      ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"],
      extracted_dates(text)
    )
  end

  def test_current_actual_extraction_when_only_the_first_date_is_named
    # A name before the *first* date isn't enough — the rest of the run is
    # still a bare comma-to-comma chain and collapses just the same, leaving
    # only the first date (March 3) in the result.
    text = "Birthdays: Emma March 3, March 9, April 12, May 5"
    assert_equal(["2013-03-03T00:00:00"], extracted_dates(text))
  end

  def test_naming_only_the_first_date_still_collapses_the_rest
    skip "known upstream limitation: bare comma-to-comma date runs collapse into one Entity (see file comment)"

    text = "Birthdays: Emma March 3, March 9, April 12, May 5"
    assert_equal(
      ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"],
      extracted_dates(text)
    )
  end

  def test_current_actual_extraction_for_ambiguous_leading_date_format
    # Beyond losing dates, the single :value that *does* survive isn't even
    # reliably the leftmost one: the ambiguous "3/3" here causes the SECOND
    # date (March 9) to win instead of the first, with nothing in the output
    # signaling that happened.
    text = "Birthdays: Emma 3/3, March 9, April 12, May 5"
    assert_equal(["2013-03-09T00:00:00"], extracted_dates(text))
  end

  def test_ambiguous_leading_date_format_is_not_reliably_the_resolved_value
    skip "known upstream limitation: the composed :value is not reliably the leftmost date (see file comment)"

    text = "Birthdays: Emma 3/3, March 9, April 12, May 5"
    assert_equal(
      ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"],
      extracted_dates(text)
    )
  end
end
