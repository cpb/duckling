#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders the committed corpus tests under test/wafer/ from the checked-in
# fixtures. Offline and deterministic: the same fixtures always produce the
# same bytes, which is what lets test/wafer/corpus_generation_test.rb detect a
# stale tree without a network call or a subprocess.
#
# Run through `rake corpus:generate`. See docs/wafer-corpus.md.

require "erb"
require "fileutils"
require "json"

module CorpusTests
  ROOT = File.expand_path("..", __dir__)
  TEMPLATE = File.join(ROOT, "script/templates/corpus_test.rb.erb")
  OUTPUT_DIR = File.join(ROOT, "test/wafer")

  # The fixture the extractor writes. The other one is hand-written, and the
  # two get different provenance headers.
  EXTRACTED_FIXTURE = "wafer_corpus.json"

  FIXTURES = {
    EXTRACTED_FIXTURE => nil,
    "wafer_corpus_local.json" => "local"
  }.freeze

  # Maps a check to the dimension directory it lands in. The upstream corpus
  # file stem would do for all but the local additions, which have no
  # corpus file of their own.
  DIMENSIONS = {
    "time_naive" => "time", "time_instant" => "time", "time_interval" => "time",
    "time_open_interval_after" => "time", "time_open_interval_before" => "time",
    "time_interval_with_context" => "time", "no_time" => "time",
    "money" => "amount_of_money", "cc" => "credit_card_number", "no_cc" => "credit_card_number",
    "distance" => "distance", "duration" => "duration", "no_duration" => "duration",
    "email" => "email", "no_email" => "email", "numeral" => "numeral", "ordinal" => "ordinal",
    "phone" => "phone_number", "no_phone" => "phone_number",
    "quantity" => "quantity", "quantity_with_product" => "quantity",
    "temperature" => "temperature", "url" => "url", "no_url" => "url", "volume" => "volume"
  }.freeze

  module_function

  def fixture_path(name)
    File.join(ROOT, "test/fixtures", name)
  end

  def load_fixture(name)
    JSON.parse(File.read(fixture_path(name), encoding: "UTF-8"))
  end

  # Every generated file, as {absolute path => contents}. Rendering to strings
  # rather than straight to disk is what lets the staleness test compare
  # without writing anything.
  def render_all
    with_utf8_external do
      template = ERB.new(File.read(TEMPLATE, encoding: "UTF-8"), trim_mode: "-")

      buckets(FIXTURES.flat_map { |name, dimension| annotate(load_fixture(name), name, dimension) })
        .sort_by { |(dimension, check), _| [dimension, check] }
        .to_h do |(dimension, check), cases|
          path = File.join(OUTPUT_DIR, dimension, "#{file_stem(dimension, check)}_test.rb")
          [path, render(template, dimension, check, cases)]
        end
    end
  end

  # Renders the same bytes whatever the host's locale is. `String#inspect`
  # would otherwise escape non-ASCII on a US-ASCII host. Process-global state,
  # hence the ensure. See docs/wafer-corpus.md.
  def with_utf8_external
    previous = Encoding.default_external
    return yield if previous == Encoding::UTF_8

    Encoding.default_external = Encoding::UTF_8
    begin
      yield
    ensure
      Encoding.default_external = previous
    end
  end

  # Every *_test.rb under test/wafer/ is generated, with no hand-written file
  # mixed in (the staleness test lives outside that tree on purpose), so a
  # file no longer rendered is an orphan and gets removed.
  def existing_files
    Dir[File.join(OUTPUT_DIR, "**", "*_test.rb")].sort
  end

  def write_all
    rendered = render_all

    (existing_files - rendered.keys).each { |orphan| File.delete(orphan) }
    rendered.each do |path, contents|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents, encoding: "UTF-8")
    end

    rendered.keys
  end

  # Tags each case with the fixture it came from and the directory it belongs
  # in. `dimension` is nil for the extracted fixture, whose cases carry a
  # corpus file to derive it from. The fixture name comes from the loader
  # rather than from a case field, so a local case is labelled by where it
  # lives and not by what its `file` happens to look like.
  def annotate(fixture, name, dimension)
    fixture.fetch("cases").map do |kase|
      kase.merge(
        "fixture" => name,
        "dimension" => dimension || DIMENSIONS.fetch(kase.fetch("check"))
      )
    end
  end

  def buckets(cases)
    cases.group_by { |kase| [kase.fetch("dimension"), kase.fetch("check")] }
  end

  # `time_naive` in the time directory reads better as `naive`. Checks that do
  # not repeat their directory keep their own name.
  def file_stem(dimension, check)
    check.delete_prefix("#{dimension}_")
  end

  def render(template, dimension, check, cases)
    grouped = cases.group_by { |kase| kase.fetch("group") }

    # Two upstream `#[test] fn`s in different corpus files can share a name and
    # land in one bucket. `group_by` would merge them into a single method
    # whose origin comment names only the first file, so refuse instead. A name
    # cannot repeat inside one file, which makes spanning files the whole test.
    spanning = grouped.select { |_, group_cases| files_in(group_cases).length > 1 }
    if spanning.any?
      detail = spanning.map { |name, group_cases| "#{name} (#{files_in(group_cases).join(", ")})" }
      raise "Group name spans corpus files in #{dimension}/#{check}: #{detail.join("; ")}"
    end

    groups = grouped.map { |name, group_cases| build_group(name, group_cases) }
      .sort_by { |group| group.fetch(:sort_key) }

    template.result(binding_for(
      source: "test/fixtures/#{cases.first.fetch("fixture")}",
      provenance: provenance(cases),
      class_name: class_name(dimension, check),
      groups: groups
    ))
  end

  def files_in(cases)
    cases.map { |kase| kase.fetch("file") }.uniq.sort
  end

  def build_group(name, cases)
    ordered = cases.sort_by { |kase| kase.fetch("line") }
    first = ordered.first
    {
      name: name,
      origin: "#{first.fetch("file")}:#{first.fetch("line")}",
      sort_key: [first.fetch("file"), first.fetch("line")],
      assertions: ordered.map { |kase| assertion_for(kase) }
    }
  end

  def provenance(cases)
    unless cases.first.fetch("fixture") == EXTRACTED_FIXTURE
      return "hand-written local additions, not extracted from upstream"
    end

    sha = load_fixture(EXTRACTED_FIXTURE).dig("upstream", "sha")
    "wafer-inc/duckling @ #{sha[0, 7]}, tests/#{files_in(cases).join(", tests/")}"
  end

  def class_name(dimension, check)
    # Flat, not nested: a `Wafer::Time` module would shadow ::Time inside the
    # very files that test time values.
    "Wafer#{camelize(dimension)}#{camelize(file_stem(dimension, check))}Test"
  end

  def camelize(name)
    name.split("_").map(&:capitalize).join
  end

  def assertion_for(kase)
    check = kase.fetch("check")
    text = kase.fetch("text")
    expected = kase.fetch("expected")

    # Already-rendered Ruby source, not values: the with-context checker needs
    # a keyword argument, which has no literal form to inspect.
    literals =
      case check
      when "no_time", "no_email", "no_url", "no_phone", "no_cc", "no_duration" then []
      when "url" then [expected.fetch("value"), expected.fetch("domain")].map(&:inspect)
      when "cc" then [expected.fetch("value"), expected.fetch("issuer")].map(&:inspect)
      when "duration", "time_naive", "time_instant",
        "time_open_interval_after", "time_open_interval_before"
        [expected.fetch("value").inspect, expected.fetch("grain").to_sym.inspect]
      when "money", "distance", "volume", "temperature", "quantity"
        [expected.fetch("value"), expected.fetch("unit")].map(&:inspect)
      when "quantity_with_product"
        [expected.fetch("value"), expected.fetch("unit"), expected.fetch("product")].map(&:inspect)
      when "time_interval"
        [expected.fetch("from").inspect, expected.fetch("to").inspect, expected.fetch("grain").to_sym.inspect]
      when "time_interval_with_context"
        [expected.fetch("from").inspect, expected.fetch("to").inspect, expected.fetch("grain").to_sym.inspect,
          "context: #{kase.fetch("context").inspect}"]
      else [expected.fetch("value").inspect]
      end

    "#{ASSERTIONS.fetch(check)} #{([text.inspect] + literals).join(", ")}"
  end

  ASSERTIONS = {
    "numeral" => "assert_numeral", "ordinal" => "assert_ordinal",
    "email" => "assert_email", "no_email" => "assert_no_email",
    "url" => "assert_url", "no_url" => "assert_no_url",
    "phone" => "assert_phone", "no_phone" => "assert_no_phone",
    "cc" => "assert_credit_card", "no_cc" => "assert_no_credit_card",
    "duration" => "assert_duration", "no_duration" => "assert_no_duration",
    "money" => "assert_money", "distance" => "assert_distance",
    "volume" => "assert_volume", "temperature" => "assert_temperature",
    "quantity" => "assert_quantity", "quantity_with_product" => "assert_quantity_with_product",
    "time_naive" => "assert_time_naive", "time_instant" => "assert_time_instant",
    "time_interval" => "assert_time_interval", "time_interval_with_context" => "assert_time_interval",
    "time_open_interval_after" => "assert_time_open_interval_after",
    "time_open_interval_before" => "assert_time_open_interval_before",
    "no_time" => "assert_no_time"
  }.freeze

  # ERB#result takes a binding, so give it one holding exactly the template's
  # variables and nothing else.
  def binding_for(source:, provenance:, class_name:, groups:)
    binding
  end
end

if __FILE__ == $PROGRAM_NAME
  warn "Wrote #{CorpusTests.write_all.length} corpus test files under test/wafer/"
end
