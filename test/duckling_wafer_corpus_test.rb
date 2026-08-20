# frozen_string_literal: true

require "test_helper"
require "json"

# Replays the wafer-inc/duckling EN corpora through Duckling.parse.
#
# test/fixtures/wafer_corpus.json holds every check_* call site extracted from
# the upstream tests/*_corpus.rs files; test/fixtures/wafer_corpus_local.json
# holds hand-written additions. Both are BSD-3-Clause derived data — see
# NOTICES. Regenerate the extracted one with `rake corpus:refresh`.
#
# The matchers below mirror the upstream Rust checkers exactly, including the
# rule that a measurement Interval matches when EITHER bound matches value and
# unit. A Value-only matcher reports 93 false failures on interval phrasings
# such as "between 10 and 20 dollars". See docs/wafer-corpus.md.
class DucklingWaferCorpusTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("fixtures", __dir__)

  # The corpora anchor every relative expression on one Tuesday. The two
  # named contexts sit inside a weekend, which is what this/next/last weekend
  # resolution turns on.
  REFERENCE_TIMES = {
    nil => Time.new(2013, 2, 12, 4, 30, 0, "-02:00"),
    "saturday" => Time.new(2013, 2, 9, 10, 0, 0, "-02:00"),
    "friday_evening" => Time.new(2013, 2, 8, 20, 0, 0, "-02:00")
  }.freeze

  DIMS = {
    "money" => "amount-of-money", "cc" => "credit-card-number", "no_cc" => "credit-card-number",
    "distance" => "distance", "duration" => "duration", "no_duration" => "duration",
    "email" => "email", "no_email" => "email", "numeral" => "number", "ordinal" => "ordinal",
    "phone" => "phone-number", "no_phone" => "phone-number",
    "quantity" => "quantity", "quantity_with_product" => "quantity",
    "temperature" => "temperature", "url" => "url", "no_url" => "url", "volume" => "volume",
    "time_naive" => "time", "time_instant" => "time", "time_interval" => "time",
    "time_open_interval_after" => "time", "time_open_interval_before" => "time",
    "time_interval_with_context" => "time", "no_time" => "time"
  }.freeze

  MEASUREMENTS = {
    "money" => :AmountOfMoney, "distance" => :Distance,
    "volume" => :Volume, "temperature" => :Temperature
  }.freeze

  # Upstream compares f64s with `(a - b).abs() < 0.01`.
  TOLERANCE = 0.01

  def self.load_fixture(name)
    JSON.parse(File.read(File.join(FIXTURE_DIR, name), encoding: "UTF-8"))
  end

  def self.cases
    load_fixture("wafer_corpus.json").fetch("cases") + load_fixture("wafer_corpus_local.json").fetch("cases")
  end

  # One test method per upstream `#[test] fn`, so a failure names the same
  # group a Rust `cargo test` failure would. All of a group's cases are tried
  # before the assertion, so one refresh reports every case it broke rather
  # than the first.
  cases.group_by { |kase| [kase.fetch("file"), kase.fetch("group")] }.each do |(file, group), group_cases|
    stem = File.basename(file, ".rs").delete_suffix("_corpus")
    name = :"test_#{stem}_#{group.delete_prefix("test_")}"
    raise "Duplicate corpus test method #{name}" if method_defined?(name)

    define_method(name) do
      failures = group_cases.filter_map { |kase| describe_failure(kase) }
      # Not assert_empty: it appends its own dump of the array, which here is
      # the same text the message already carries, twice over.
      assert failures.empty?,
        "#{failures.length} of #{group_cases.length} #{file} cases failed:\n#{failures.join("\n")}"
    end
  end

  # A botched refresh that drops most of the corpus still leaves every
  # remaining group green, so pin the counts the extractor writes.
  def test_extracted_fixture_metadata_matches_its_cases
    fixture = self.class.load_fixture("wafer_corpus.json")
    assert_match(/\A[0-9a-f]{40}\z/, fixture.dig("upstream", "sha"))
    assert_equal fixture.fetch("case_count"), fixture.fetch("cases").length
    assert_operator fixture.fetch("case_count"), :>=, 1656,
      "the corpus shrank. If upstream really dropped cases, lower this floor deliberately"
  end

  def test_local_fixture_metadata_matches_its_cases
    fixture = self.class.load_fixture("wafer_corpus_local.json")
    assert_equal fixture.fetch("case_count"), fixture.fetch("cases").length
  end

  def test_every_case_names_a_check_the_runner_knows
    unknown = self.class.cases.map { |kase| kase.fetch("check") }.uniq - DIMS.keys
    assert_empty unknown, "fixture cases use checks the runner cannot dispatch"
  end

  private

  def describe_failure(kase)
    entities = parse_case(kase)
    return nil if match?(kase, entities)
    "  #{kase.fetch("file")}:#{kase.fetch("line")} #{kase.fetch("text").inspect} " \
      "expected #{kase.fetch("check")} #{kase.fetch("expected").inspect}, " \
      "got #{entities.map { |entity| entity[:value] }.inspect}"
  rescue => error
    "  #{kase.fetch("file")}:#{kase.fetch("line")} #{kase.fetch("text").inspect} raised #{error.class}: #{error.message}"
  end

  def parse_case(kase)
    check = kase.fetch("check")
    kwargs = {locale: "en", dims: [DIMS.fetch(check)]}
    # Only the time corpora depend on an anchor moment. The rest call
    # upstream's parse_en, which supplies its own default context.
    kwargs[:reference_time] = REFERENCE_TIMES.fetch(kase["context"]) if DIMS.fetch(check) == "time"
    Duckling.parse(kase.fetch("text"), **kwargs)
  end

  def match?(kase, entities)
    check = kase.fetch("check")
    return entities.empty? if check.start_with?("no_")

    expected = kase.fetch("expected")
    values = entities.map { |entity| entity[:value] }

    case check
    when "numeral" then values.any? { |value| close?(value[:Numeral], expected.fetch("value")) }
    when "ordinal" then values.any? { |value| value[:Ordinal] == expected.fetch("value") }
    when "email" then values.any? { |value| value[:Email] == expected.fetch("value") }
    when "phone" then values.any? { |value| value[:PhoneNumber] == expected.fetch("value") }
    when "url"
      values.any? do |value|
        (url = value[:Url]) && url[:value] == expected.fetch("value") && url[:domain] == expected.fetch("domain")
      end
    when "cc"
      values.any? do |value|
        (card = value[:CreditCardNumber]) &&
          card[:value] == expected.fetch("value") && card[:issuer] == expected.fetch("issuer")
      end
    when "duration"
      values.any? do |value|
        (duration = value[:Duration]) &&
          duration[:value] == expected.fetch("value") && duration[:grain] == expected.fetch("grain").to_sym
      end
    when *MEASUREMENTS.keys
      values.any? { |value| measurement?(value[MEASUREMENTS.fetch(check)], expected) }
    when "quantity", "quantity_with_product"
      values.any? do |value|
        quantity = value[:Quantity]
        next false unless quantity
        next false if expected.key?("product") && quantity[:product] != expected.fetch("product")
        measurement?(quantity[:measurement], expected)
      end
    when "time_naive", "time_instant"
      tag = (check == "time_naive") ? :Naive : :Instant
      values.any? do |value|
        point = value.dig(:Time, :Single, :value, tag)
        point && wall_clock(point[:value]) == expected.fetch("value") && point[:grain] == expected.fetch("grain").to_sym
      end
    when "time_interval", "time_interval_with_context"
      values.any? do |value|
        interval = value.dig(:Time, :Interval)
        next false unless interval && interval[:from] && interval[:to]
        from = leaf(interval[:from])
        to = leaf(interval[:to])
        # Upstream accepts the grain on either leg, not on both.
        wall_clock(from[:value]) == expected.fetch("from") &&
          wall_clock(to[:value]) == expected.fetch("to") &&
          [from[:grain], to[:grain]].include?(expected.fetch("grain").to_sym)
      end
    when "time_open_interval_after", "time_open_interval_before"
      open_leg = (check == "time_open_interval_after") ? :from : :to
      closed_leg = (open_leg == :from) ? :to : :from
      values.any? do |value|
        interval = value.dig(:Time, :Interval)
        next false unless interval && interval[open_leg] && interval[closed_leg].nil?
        point = leaf(interval[open_leg])
        wall_clock(point[:value]) == expected.fetch("value") && point[:grain] == expected.fetch("grain").to_sym
      end
    else
      raise "Unknown corpus check #{check.inspect}"
    end
  end

  # Mirrors the Rust measurement checkers: a Value matches on value and unit,
  # and an Interval matches when either bound does.
  def measurement?(measurement, expected)
    return false unless measurement

    if (single = measurement[:Value])
      point?(single, expected)
    elsif (interval = measurement[:Interval])
      [interval[:from], interval[:to]].compact.any? { |bound| point?(bound, expected) }
    else
      false
    end
  end

  def point?(point, expected)
    close?(point[:value], expected.fetch("value")) && point[:unit] == expected.fetch("unit")
  end

  def close?(actual, expected)
    actual.is_a?(Numeric) && (actual - expected).abs < TOLERANCE
  end

  # Upstream compares a NaiveDateTime, and reads an Instant through
  # `naive_local()`. Both are the leaf's own wall clock.
  def wall_clock(time)
    [time.year, time.month, time.day, time.hour, time.min, time.sec]
  end

  def leaf(tagged)
    tagged[:Naive] || tagged[:Instant]
  end
end
