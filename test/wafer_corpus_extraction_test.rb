# frozen_string_literal: true

require "test_helper"
require_relative "../script/extract_wafer_corpus"
require_relative "../script/generate_corpus_tests"

# Pins the corpus pipeline's parsing and its guards. The corpus at the pinned
# sha exercises none of these edges, so without this file each one is a latent
# bug that a future `rake corpus:refresh` would hit with no warning. The
# staleness test next door covers the rendered tree instead. See
# docs/wafer-corpus.md.
class WaferCorpusExtractionTest < Minitest::Test
  # A Rust literal decodes in one left-to-right pass. Two chained gsubs let the
  # first one's output be re-read by the second, so an escaped backslash before
  # `u{` would decode as if it introduced a codepoint.
  def test_unquote_does_not_decode_an_escaped_backslash_as_an_escape
    assert_equal '\u{41}', WaferCorpus.unquote('"\\\\u{41}"')
  end

  def test_unquote_decodes_the_escapes_rust_allows
    assert_equal "A", WaferCorpus.unquote('"\u{41}"')
    assert_equal "AB", WaferCorpus.unquote('"\x41B"')
    assert_equal %(a"b\\c\nd), WaferCorpus.unquote('"a\"b\\\\c\nd"')
    assert_equal "10¢", WaferCorpus.unquote('"10\u{A2}"')
  end

  def test_unquote_leaves_unescaped_text_alone
    assert_equal 'over 5"', WaferCorpus.unquote('"over 5\""')
  end

  def test_parse_expectation_keeps_the_plain_numeric_forms
    assert_equal(-2, WaferCorpus.parse_expectation("-2"))
    assert_in_delta 98.6, WaferCorpus.parse_expectation("98.6")
  end

  # Rust separators, exponents, and type suffixes are all well-formed literals
  # upstream could introduce. Raising on one would fail a refresh confusingly.
  def test_parse_expectation_accepts_the_other_rust_numeric_forms
    assert_equal 1000, WaferCorpus.parse_expectation("1_000")
    assert_equal 7, WaferCorpus.parse_expectation("7u32")
    assert_in_delta 100000.0, WaferCorpus.parse_expectation("1e5")
    assert_in_delta 1.0, WaferCorpus.parse_expectation("1.0f64")
  end

  def test_parse_expectation_still_rejects_an_unrecognized_argument
    error = assert_raises(RuntimeError) { WaferCorpus.parse_expectation("wat") }
    assert_match(/Unrecognized corpus argument/, error.message)
  end

  # A `//` inside a string literal is not a comment. Reading one as a comment
  # would drop a live call site from the fixture silently.
  def test_commented_out_ignores_a_double_slash_inside_a_string
    line = 'let u = "https://x"; check_url('
    refute WaferCorpus.commented_out?(line, line.length)
  end

  def test_commented_out_detects_a_real_comment_anywhere_on_the_line
    ["    // check_url(", "foo(); // check_url("].each do |line|
      assert WaferCorpus.commented_out?(line, line.length), line
    end
  end

  def test_commented_out_leaves_a_live_call_alone
    line = "    check_url("
    refute WaferCorpus.commented_out?(line, line.length)
  end

  # A placeholder group name would make the generator merge every affected
  # case into one method, so the extraction has to fail instead.
  def test_enclosing_test_raises_when_there_is_no_enclosing_fn
    error = assert_raises(RuntimeError) { WaferCorpus.enclosing_test("no function here", 10) }
    assert_match(/No enclosing fn/, error.message)
  end

  def test_enclosing_test_names_the_enclosing_fn
    source = "fn test_money() {\n  check_money("
    assert_equal "test_money", WaferCorpus.enclosing_test(source, source.length)
  end

  # Two upstream `#[test] fn`s in different corpus files can share a name.
  # Grouping by name alone would merge them into one method, keeping only the
  # first file's origin comment.
  def test_render_refuses_a_group_name_that_spans_corpus_files
    error = assert_raises(RuntimeError) do
      CorpusTests.render(template, "numeral", "numeral",
        [numeral_case(file: "a_corpus.rs"), numeral_case(file: "b_corpus.rs")])
    end
    assert_match(/Group name spans corpus files/, error.message)
    assert_match(/a_corpus\.rs, b_corpus\.rs/, error.message)
  end

  def test_render_accepts_distinct_group_names_from_one_file
    rendered = CorpusTests.render(template, "numeral", "numeral",
      [numeral_case(group: "test_a"), numeral_case(group: "test_b")])

    assert_match(/def test_a\b/, rendered)
    assert_match(/def test_b\b/, rendered)
  end

  # Provenance comes from the fixture a case was loaded from, not from what its
  # `file` field looks like, so a local case mimicking upstream's layout cannot
  # claim the extracted fixture's sha.
  def test_provenance_labels_a_local_case_by_its_fixture
    local = [numeral_case(file: "time_corpus.rs", fixture: "wafer_corpus_local.json")]

    assert_equal "hand-written local additions, not extracted from upstream",
      CorpusTests.provenance(local)
  end

  def test_provenance_gives_an_upstream_case_the_sha_trail
    assert_match %r{\Awafer-inc/duckling @ \h{7}, tests/numeral_corpus\.rs\z},
      CorpusTests.provenance([numeral_case(file: "numeral_corpus.rs")])
  end

  private

  def template
    ERB.new(File.read(CorpusTests::TEMPLATE, encoding: "UTF-8"), trim_mode: "-")
  end

  def numeral_case(file: "numeral_corpus.rs", group: "test_numeral", fixture: CorpusTests::EXTRACTED_FIXTURE)
    {
      "check" => "numeral", "text" => "one", "expected" => {"value" => 1.0},
      "file" => file, "line" => 1, "group" => group,
      "fixture" => fixture, "dimension" => "numeral"
    }
  end
end
