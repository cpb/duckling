# frozen_string_literal: true

require "test_helper"
require_relative "../script/generate_corpus_tests"

# Guards the two fixtures under test/fixtures/ and the tree generated from
# them under test/wafer/. Deliberately outside test/wafer/, so that every
# *_test.rb in there is generated with no hand-written file mixed in — which
# is what makes the orphan check below a simple set comparison.
#
# The generator renders to strings, so this compares against disk in-process:
# no subprocess, no network, no git. See docs/wafer-corpus.md.
class WaferCorpusGenerationTest < Minitest::Test
  def test_generated_files_are_current
    CorpusTests.render_all.each do |path, expected|
      relative = path.delete_prefix("#{CorpusTests::ROOT}/")
      assert_equal expected, File.read(path, encoding: "UTF-8"),
        "#{relative} is stale. Run `bundle exec rake corpus:generate`."
    end
  end

  # `with_utf8_external` in the generator is what makes rendering
  # locale-independent. Every CI host is UTF-8, so losing that pin would go
  # unnoticed there and surface only for a contributor whose host is not.
  # Driving one render from US-ASCII catches it in process.
  def test_rendering_does_not_depend_on_the_host_locale
    rendered = with_external_encoding(Encoding::US_ASCII) { CorpusTests.render_all }

    rendered.each do |path, expected|
      relative = path.delete_prefix("#{CorpusTests::ROOT}/")
      assert_equal expected, File.read(path, encoding: "UTF-8"),
        "#{relative} renders differently on a US-ASCII host. See with_utf8_external in script/generate_corpus_tests.rb."
    end
  end

  def test_no_orphaned_generated_files
    orphans = CorpusTests.existing_files - CorpusTests.render_all.keys
    assert_empty orphans.map { |path| path.delete_prefix("#{CorpusTests::ROOT}/") },
      "test/wafer/ holds files the fixtures no longer produce. Run `bundle exec rake corpus:generate`."
  end

  # A botched refresh that drops most of the corpus still leaves every
  # remaining test green, so pin the counts the extractor writes.
  def test_extracted_fixture_metadata_matches_its_cases
    fixture = CorpusTests.load_fixture("wafer_corpus.json")
    assert_match(/\A[0-9a-f]{40}\z/, fixture.dig("upstream", "sha"))
    assert_equal fixture.fetch("case_count"), fixture.fetch("cases").length
    assert_operator fixture.fetch("case_count"), :>=, 1656,
      "the corpus shrank. If upstream really dropped cases, lower this floor deliberately"
  end

  def test_local_fixture_metadata_matches_its_cases
    fixture = CorpusTests.load_fixture("wafer_corpus_local.json")
    assert_equal fixture.fetch("case_count"), fixture.fetch("cases").length
  end

  def test_every_case_names_a_check_the_generator_knows
    checks = CorpusTests::FIXTURES.keys
      .flat_map { |name| CorpusTests.load_fixture(name).fetch("cases") }
      .map { |kase| kase.fetch("check") }
      .uniq

    assert_empty checks - CorpusTests::ASSERTIONS.keys, "fixture cases use checks with no assertion"
  end

  private

  # $VERBOSE is silenced because Ruby warns on every assignment to
  # Encoding.default_external under the suite's -w.
  def with_external_encoding(encoding)
    previous = Encoding.default_external
    verbose, $VERBOSE = $VERBOSE, nil
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = previous
    $VERBOSE = verbose
  end
end
