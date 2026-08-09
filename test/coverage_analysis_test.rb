# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "support/coverage_report"
require_relative "support/coverage_manifest"

# Synthesized per-leg resultsets, standing in for a real five-leg CI run.
#
# Fixtures rather than this repo's own coverage on purpose: real coverage
# depends on which tz database the host has, so asserting on it would make
# these tests say different things on different machines — the failure mode
# the analysis itself exists to expose.
#
# The subject is a file shaped like this, so there is one `if` with both arms
# at known positions:
#
#   1  # frozen_string_literal: true
#   2
#   3  def remedy(links)
#   4    if links
#   5      "no remedy needed"
#   6    else
#   7      "install tzdata-legacy"
#   8    end
#   9  end
module CoverageFixtures
  IF = "[:if, 0, 4, 2, 8, 5]"
  THEN = "[:then, 1, 5, 4, 5, 23]"
  ELSE = "[:else, 2, 7, 4, 7, 26]"

  # `subject` names the file the synthesized coverage is attributed to. The
  # default does not exist: the report reads the real file for its excerpt, and
  # an absent one has to degrade to "no excerpt" rather than take the analysis
  # down. QUOTED points at a file that does exist, for the excerpt itself.
  QUOTED = "test/support/coverage_analysis.rb"

  # SimpleCov's on-disk shape: a hit count per line (nil where Ruby tracks
  # nothing), and a nested branch map keyed by the stringified Coverage tuples.
  def resultset(leg, file, lines:, branches: {})
    {leg => {"coverage" => {file => {"lines" => lines, "branches" => branches}}, "timestamp" => 0}}
  end

  def lines_for(then_hits, else_hits)
    [nil, nil, 1, nil, then_hits, nil, else_hits, nil, nil]
  end

  # A leg mapped to nil reports nothing about the file at all, which is how a
  # leg that never loaded it differs from one that loaded it and ran nothing.
  def with_legs(legs, subject: "lib/subject.rb")
    Dir.mktmpdir do |dir|
      file = File.join(CoverageAnalysis::ROOT, subject)

      legs.each do |leg, hits|
        FileUtils.mkdir_p(File.join(dir, leg))
        content = if hits.nil?
          {leg => {"coverage" => {}, "timestamp" => 0}}
        else
          then_hits, else_hits = hits
          resultset(leg, file,
            lines: lines_for(then_hits, else_hits),
            branches: {IF => {THEN => then_hits, ELSE => else_hits}})
        end

        File.write(File.join(dir, leg, ".resultset.json"), JSON.dump(content))
      end

      yield CoverageAnalysis.resultsets(dir)
    end
  end
end

# The cross-leg merge, and the attribution built on it.
class CoverageAnalysisTest < Minitest::Test
  include CoverageFixtures

  def test_a_branch_no_leg_reaches_is_the_headline_finding
    with_legs({"with-links" => [3, 0], "without-links" => [2, 0]}) do |legs|
      unreached = CoverageAnalysis.unreached(legs)

      # The `else` line and the `else` branch both, since the arm was never
      # entered at all — a branch whose body is one line reports as each.
      assert_equal ["else of `if` at line 4", "line"], unreached.map(&:label)
      assert_equal [7, 7], unreached.map(&:line)
      assert_empty unreached.flat_map(&:legs)
    end
  end

  # The failure this analysis was built for: every leg runs the test, every
  # leg passes, and one arm has never been evaluated by any of them. A
  # per-leg report cannot say this — each leg's own report shows the arm
  # uncovered and cannot tell that from "another leg covers it".
  def test_a_branch_one_leg_reaches_is_not_a_finding_but_is_attributed
    with_legs({"with-links" => [3, 0], "without-links" => [0, 4]}) do |legs|
      assert_empty CoverageAnalysis.unreached(legs)

      dependent = CoverageAnalysis.tz_dependent(legs)

      assert_equal [["with-links"], ["without-links"]], dependent.map(&:legs).uniq.sort
      assert_equal ["else of `if` at line 4", "then of `if` at line 4"],
        dependent.map(&:label).grep(/of `if`/).sort
    end
  end

  def test_summary_counts_every_leg_against_the_merged_denominator
    with_legs({"with-links" => [3, 0], "without-links" => [0, 4]}) do |legs|
      summary = CoverageAnalysis.summary(legs)

      assert_equal [1, 2], summary.fetch("with-links")[:branches]
      assert_equal [1, 2], summary.fetch("without-links")[:branches]
      assert_equal [2, 2], summary.fetch("merged")[:branches]
    end
  end

  def test_two_resultsets_under_one_leg_name_cannot_be_attributed
    Dir.mktmpdir do |dir|
      %w[first second].each do |directory|
        FileUtils.mkdir_p(File.join(dir, directory))
        File.write(File.join(dir, directory, ".resultset.json"),
          JSON.dump(resultset("same-leg", "/x.rb", lines: [1])))
      end

      error = assert_raises(RuntimeError) { CoverageAnalysis.resultsets(dir) }
      assert_match(/appears twice/, error.message)
    end
  end

  # Safe navigation is a branch whose type is the symbol :"&." — it inspects
  # with quotes, which is the one shape that does not parse like the others.
  def test_safe_navigation_branches_are_parsed
    assert_equal 165, CoverageAnalysis.branch_line(%([:"&.", 27, 165, 6, 165, 27]))
    assert_equal "then of `&.` at line 165",
      CoverageAnalysis.branch_label(%([:"&.", 27, 165, 6, 165, 27]), %([:then, 28, 165, 6, 165, 27]))
  end

  # A leg that never loaded a file says nothing about it — neither "covered"
  # nor "unreached". Only the legs that loaded it get a vote, so a partial run
  # merged in by accident cannot manufacture a blind spot.
  def test_a_leg_that_never_loaded_the_file_is_not_counted_against_it
    with_legs({"loaded" => [3, 1], "never-loaded" => nil}) do |legs|
      assert_empty CoverageAnalysis.unreached(legs)
      assert_equal [["loaded"]], CoverageAnalysis.tz_dependent(legs).map(&:legs).uniq
    end
  end

  def test_report_of_no_resultsets_says_so_rather_than_reporting_perfection
    assert_match(/No coverage resultsets found/, CoverageReport.render({}))
  end

  def test_report_of_a_leg_that_tracked_nothing_does_not_divide_by_zero
    with_legs({"empty" => nil}) do |legs|
      assert_match(%r{\| 0 / 0 \|}, CoverageReport.render(legs))
    end
  end

  def test_report_names_the_legs_it_merged
    with_legs({"with-links" => [3, 0], "without-links" => [0, 4]}) do |legs|
      report = CoverageReport.render(legs)

      assert_match(/Merged across 2 tz legs: with-links, without-links/, report)
      assert_match(/Reached by no leg \(0\)/, report)
      assert_match(/— only this leg/, report)
    end
  end

  # Singular/plural and the "only this leg" note are the two places the report
  # phrases a count, and one leg is how it is read locally.
  def test_report_of_one_leg_reads_as_one_leg
    with_legs({"solo" => [1, 0]}) do |legs|
      report = CoverageReport.render(legs)

      assert_match(/Merged across 1 tz leg: solo/, report)
      assert_match(/Reached by no leg \(2\)/, report)
      assert_match(/Reached by some legs but not all \(0\)/, report)
    end
  end

  # Three legs, split two-to-one, so the group headed by more than one leg is
  # rendered without the "only this leg" note.
  def test_report_groups_a_finding_by_the_exact_set_of_legs_that_reached_it
    with_legs({"a" => [1, 0], "b" => [1, 0], "c" => [0, 1]}) do |legs|
      report = CoverageReport.render(legs)

      assert_match(/### `a`, `b` \(2\)\n/, report)
      assert_match(/### `c` \(2\) — only this leg/, report)
    end
  end

  def test_report_quotes_the_source_line_so_a_reader_need_not_open_the_file
    with_legs({"solo" => [1, 0]}, subject: QUOTED) do |legs|
      quoted = CoverageAnalysis.source_line(QUOTED, 7).strip

      assert_includes CoverageReport.render(legs), "- L7 — line: `#{quoted}`"
    end
  end
end

# The gate over the analysis: what test/coverage_manifest.yml has to declare,
# and the three ways a run fails against it.
class CoverageManifestTest < Minitest::Test
  include CoverageFixtures

  Finding = CoverageAnalysis::Finding

  # The `else` arm of the fixture, which no leg takes when every leg is given
  # else_hits of 0 — the shape of the finding this whole gate is for.
  UNREACHED_ELSE = "else of `if` at line 4"

  # What a declaration names: the same branch with its position stripped, so
  # the entry survives an edit anywhere above line 4.
  UNREACHED_ELSE_KIND = "else of `if`"

  def declaration(file, label, source)
    {"file" => file, "label" => label, "source" => source, "reason" => "because"}
  end

  # The default subject does not exist on disk, so these findings carry no
  # source excerpt — a problem line still has to name the file, the position
  # and the branch, which is all a reader needs to go and look.
  # The position a label renders is not part of what an entry matches, or
  # every declaration would rot the moment a line was added above its branch.
  def test_a_declaration_matches_the_branch_wherever_the_branch_has_moved_to
    finding = Finding.new(file: "lib/duckling.rb", label: "else of `if` at line 999", source: "  raise\n")
    entry = CoverageManifest.declarations("expected" => [declaration("lib/duckling.rb", "else of `if`", "raise")]).first

    assert entry.matches?(finding)
  end

  def test_an_undeclared_unreached_branch_fails_the_run
    with_legs({"a" => [1, 0], "b" => [2, 0]}) do |legs|
      failed, message = CoverageManifest.verdict(legs, {"legs" => %w[a b], "expected" => []})

      assert failed
      assert_match(/lib\/subject\.rb:7  #{Regexp.escape(UNREACHED_ELSE)} is reached by no leg/o, message)
      assert_match(/does not declare it/, message)
    end
  end

  # And where the file does exist, the problem line quotes it, so the whole
  # finding is legible without opening anything.
  def test_the_failure_quotes_the_line_when_there_is_one_to_quote
    with_legs({"a" => [1, 0], "b" => [2, 0]}, subject: QUOTED) do |legs|
      failed, message = CoverageManifest.verdict(legs, {"legs" => %w[a b], "expected" => []})

      assert failed
      assert_includes message, "#{QUOTED}:7  #{UNREACHED_ELSE}  #{CoverageAnalysis.source_line(QUOTED, 7).strip}"
    end
  end

  def test_declaring_it_clears_the_run
    with_legs({"a" => [1, 0], "b" => [2, 0]}, subject: QUOTED) do |legs|
      # Only the branch is declared. The unreached *line* at the same position
      # is in a test file, which the skip manifest governs — declaring it here
      # too would be an entry that matches nothing.
      quoted = CoverageAnalysis.source_line(QUOTED, 7).strip
      manifest = {"legs" => %w[a b], "expected" => [declaration(QUOTED, UNREACHED_ELSE_KIND, quoted)]}

      failed, message = CoverageManifest.verdict(legs, manifest)

      refute failed, message
      assert_match(/Every unreached line and branch is declared/, message)
    end
  end

  # The check that keeps the file from turning into a graveyard: a declaration
  # whose finding went away, or whose line changed, has stopped saying anything
  # true and has to be re-read rather than left in place.
  def test_a_declaration_matching_nothing_fails_the_run
    with_legs({"a" => [1, 1], "b" => [2, 1]}, subject: QUOTED) do |legs|
      manifest = {
        "legs" => %w[a b],
        "expected" => [declaration(QUOTED, UNREACHED_ELSE_KIND, "a line that is no longer there")]
      }

      failed, message = CoverageManifest.verdict(legs, manifest)

      assert failed
      assert_match(/nothing unreached matches it/, message)
    end
  end

  def test_a_reason_is_required_of_every_declaration
    entry = declaration("lib/duckling.rb", "line", "raise").tap { |hash| hash.delete("reason") }

    assert_raises(KeyError) { CoverageManifest.declarations("expected" => [entry]) }
  end

  def test_an_unreached_line_in_a_test_file_is_left_to_the_skip_manifest
    refute CoverageManifest.governed?(Finding.new(file: "test/duckling_test.rb", label: "line"))
    assert CoverageManifest.governed?(Finding.new(file: "test/duckling_test.rb", label: "else of `if` at line 310"))
    assert CoverageManifest.governed?(Finding.new(file: "lib/duckling.rb", label: "line"))
  end

  # This repo's own manifest, held to the same three checks the suite is:
  # every declaration parses, names a file that exists, and quotes a line that
  # is really in it. A declaration pointing at nothing enforces nothing, and
  # unlike the other two failures it never surfaces on its own — the entry
  # simply matches no finding, forever.
  def test_every_declaration_quotes_a_line_that_exists_in_the_file_it_names
    CoverageManifest.declarations.each do |entry|
      path = File.join(CoverageAnalysis::ROOT, entry.file)

      assert File.exist?(path), "#{entry} names a file that does not exist"
      assert_includes CoverageAnalysis.source_lines(entry.file).map(&:strip), entry.source,
        "#{entry} quotes a line that #{entry.file} does not contain"
    end
  end

  def test_a_missing_leg_is_a_notice_locally_and_a_failure_where_every_leg_runs
    manifest = {"legs" => %w[one two], "expected" => []}

    failed, message = CoverageManifest.verdict({"one" => {}}, manifest, strict: false)
    refute failed
    assert_match(/Enforcement skipped: two did not report/, message)

    failed, message = CoverageManifest.verdict({"one" => {}}, manifest, strict: true)
    assert failed
    assert_match(/Coverage legs missing: two did not report/, message)
  end

  # Two manifests, one set of legs. The skip manifest is the source of truth —
  # a leg is a section in it — and this file has to name the same five, or the
  # merge is judged against a union it did not get. Drift in either direction
  # fails: a leg added there and not here reports coverage nobody declared, and
  # a leg dropped there and not here holds the merge open for a leg that no
  # longer runs.
  def test_the_declared_legs_are_exactly_the_skip_manifest_legs
    legs = YAML.safe_load_file(SkipManifest::PATH).keys - [SkipManifest::ALWAYS_KEY]

    assert_equal legs.sort, CoverageManifest.legs.sort
  end

  def test_a_leg_nobody_declared_is_a_failure
    failed, message = CoverageManifest.verdict({"three" => {}}, {"legs" => [], "expected" => []})

    assert failed
    assert_match(/"three" reported coverage but is not declared/, message)
  end
end
