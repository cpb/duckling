# frozen_string_literal: true

require "yaml"
require_relative "coverage_analysis"

# Holds the merged coverage to what test/coverage_manifest.yml declares.
#
# The report on its own is a log, and this repo already learned what a log is
# worth: test/support/skip_manifest.rb exists because "a skip reads as a pass
# in a CI log, and nobody diffs a log". An unreached branch is quieter than a
# skip — it reads as a *passing test*. So the same treatment applies. Every
# line and branch that no leg reaches has to be declared, with a reason, or
# the run fails.
#
# Three ways to fail, deliberately the same three as the skip manifest:
#
# - Something is unreached that nothing declares. Either it is dead code, or
#   a configuration nobody runs is the only one that would evaluate it.
# - A declaration matches nothing. The code moved, changed, or became covered
#   — in every case the entry has stopped saying anything true.
# - A leg is missing from the merge. Unreached is a claim about *all* legs, so
#   a partial merge cannot make it: fewer legs means more things look
#   unreached, and the declarations would be judged against the wrong union.
#
# The third is a notice rather than a failure when run locally, since running
# all five legs by hand is a bundle re-resolve and two built zoneinfo trees.
# In CI every leg is present, and a missing one is a failure — a leg that
# silently stopped running would otherwise widen the unreached set and get
# absorbed as new declarations.
module CoverageManifest
  PATH = ENV.fetch("DUCKLING_COVERAGE_MANIFEST") { File.expand_path("../coverage_manifest.yml", __dir__) }

  # A declaration matches on the *text* of the line and the branch's kind,
  # never on a position. Line numbers move with every edit above them, which
  # would make the file rot on contact and train everyone to re-run it blind —
  # and that includes the number inside a rendered label, which is why the
  # match is against Finding#kind rather than #label. Text moves only when the
  # code itself changes, which is exactly when a declaration deserves
  # re-reading.
  Declaration = Struct.new(:file, :label, :source, :reason) do
    def matches?(finding)
      finding.file == file && finding.kind == label && finding.source.to_s.strip == source
    end

    def to_s
      "#{file}  #{label}: #{source}"
    end
  end

  module_function

  # What the gate judges, out of everything the report shows.
  #
  # All of lib/, and every *branch* anywhere — but not a bare unreached line
  # under test/. An unreached line in a test file means the test skipped, and
  # test/skip_manifest.yml already declares every skip, leg by leg; gating it
  # here too would mean editing two files to change one test body, which is
  # how a manifest starts getting rubber-stamped. An unreached *branch* in a
  # test file is the opposite case — the test ran, reported as passing, and
  # evaluated neither arm of something. Nothing else in the suite can see
  # that, which is why this exists at all.
  def governed?(finding)
    !(finding.file.start_with?("test/") && finding.label == "line")
  end

  def load_file(path = PATH)
    YAML.safe_load_file(path)
  end

  def legs(manifest = load_file)
    Array(manifest["legs"])
  end

  def declarations(manifest = load_file)
    Array(manifest["expected"]).map do |entry|
      Declaration.new(
        file: entry.fetch("file"),
        label: entry.fetch("label"),
        source: entry.fetch("source"),
        # Required, and not read by any check. A declaration without one is a
        # silenced finding; with one it is a decision somebody can disagree
        # with later.
        reason: entry.fetch("reason")
      )
    end
  end

  def missing_legs(reported, manifest = load_file)
    legs(manifest) - reported.keys
  end

  def unexpected_legs(reported, manifest = load_file)
    reported.keys - legs(manifest)
  end

  # Empty when the merge matched the manifest; otherwise one line per
  # discrepancy.
  def problems(reported, manifest = load_file)
    findings = CoverageAnalysis.unreached(reported).select { |finding| governed?(finding) }
    declared = declarations(manifest)

    undeclared = findings.reject { |finding| declared.any? { |entry| entry.matches?(finding) } }
    stale = declared.reject { |entry| findings.any? { |finding| entry.matches?(finding) } }

    unexpected_legs(reported, manifest).map { |leg|
      "#{leg.inspect} reported coverage but is not declared in #{relative(PATH)}. " \
        "Add it to legs:, or stop collecting it."
    } + undeclared.map { |finding|
      "#{finding} is reached by no leg, and #{relative(PATH)} does not declare it. " \
        "Cover it — a new leg, or a test that reaches it — or declare it with a reason."
    } + stale.map { |entry|
      "#{entry} is declared in #{relative(PATH)}, but nothing unreached matches it. " \
        "It is covered now, or the line changed; drop the entry or update it."
    }
  end

  def relative(path)
    path.sub("#{CoverageAnalysis::ROOT}/", "")
  end

  # Renders the verdict as [failed, message].
  #
  # `strict:` is what a missing leg means. Locally it means "you ran one leg",
  # which is the normal way to use this and no reason to fail — running all
  # five by hand costs a bundle re-resolve and two built zoneinfo trees. In CI
  # every leg reports, so there it means a leg stopped running or stopped
  # uploading, and absorbing that silently is how the unreached set widens
  # without anyone deciding to widen it. DUCKLING_COVERAGE_ALL_LEGS=1 says
  # which situation this is.
  #
  # Deliberately returns rather than exits: `rake coverage:analyze` prints the
  # whole report first, and a report that stops at the first problem is worth
  # less than the problem is.
  def verdict(reported, manifest = load_file, strict: ENV["DUCKLING_COVERAGE_ALL_LEGS"] == "1")
    absent = missing_legs(reported, manifest)
    unless absent.empty?
      message = "#{absent.join(", ")} did not report. Unreached is a claim about every leg, " \
        "so it cannot be judged on a partial merge."
      return strict ? [true, "Coverage legs missing: #{message}"] : [false, "Enforcement skipped: #{message}"]
    end

    found = problems(reported, manifest)
    return [false, "Every unreached line and branch is declared in #{relative(PATH)}."] if found.empty?

    [true, (["Coverage manifest mismatch:"] + found.map { |problem| "  - #{problem}" }).join("\n")]
  end
end
