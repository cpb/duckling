# frozen_string_literal: true

require_relative "coverage_analysis"

# Renders CoverageAnalysis into Markdown — readable in a terminal, and the
# format GitHub Actions' step summary wants, so one rendering serves both.
module CoverageReport
  EMPTY = "No coverage resultsets found under coverage/. Run " \
    "`DUCKLING_COVERAGE=1 bundle exec rake test` for at least one leg, or " \
    "download the CI artifacts into coverage/.\n"

  UNREACHED_PREAMBLE = "Code no configuration in CI evaluates. A branch here asserts nothing, " \
    "wherever it sits — including inside a test that reports as passing."

  ALL_REACHED = "Every tracked line and branch is executed by at least one leg."

  TZ_DEPENDENT_PREAMBLE = "What actually depends on which tz database, and so what each leg is " \
    "buying. A line only one leg reaches is that leg's whole justification: drop the leg and it " \
    "moves to the section above."

  module_function

  def render(legs)
    return EMPTY if legs.empty?

    lines = [
      "# Cross-leg coverage",
      "",
      "Merged across #{legs.size} tz #{(legs.size == 1) ? "leg" : "legs"}: #{legs.keys.sort.join(", ")}.",
      "",
      summary_table(legs),
      "",
      unreached_section(legs),
      tz_dependent_section(legs)
    ]

    "#{lines.flatten.join("\n")}\n"
  end

  def summary_table(legs)
    rows = CoverageAnalysis.summary(legs).map do |leg, totals|
      name = (leg == "merged") ? "**merged**" : "`#{leg}`"
      "| #{name} | #{cell(totals[:lines])} | #{cell(totals[:branches])} |"
    end

    ["| leg | lines | branches |", "|---|---|---|", *rows]
  end

  def cell(covered_and_total)
    covered, total = covered_and_total
    return "#{covered} / #{total}" if total.zero?

    "#{covered} / #{total} (#{(100.0 * covered / total).round(1)}%)"
  end

  # The headline. A one-leg run puts a great deal here, which is why the
  # heading states how many legs were merged rather than a bare count.
  def unreached_section(legs)
    findings = CoverageAnalysis.unreached(legs)
    preamble = findings.empty? ? ALL_REACHED : UNREACHED_PREAMBLE

    ["## Reached by no leg (#{findings.size})", "", preamble, "", list(findings)]
  end

  # The coverage that has to be re-covered somewhere else before a leg could
  # be dropped, and the honest answer to whether a leg earns its CI minutes.
  # Grouped by the exact set of legs, so the databases that agree with each
  # other read as one group rather than as a list of near-duplicates.
  def tz_dependent_section(legs)
    findings = CoverageAnalysis.tz_dependent(legs)
    by_legs = findings.group_by { |finding| finding.legs.sort }

    ["## Reached by some legs but not all (#{findings.size})", "", TZ_DEPENDENT_PREAMBLE, "",
      by_legs.sort_by { |covering, group| [covering.size, -group.size, covering] }.map { |covering, group|
        only = (covering.size == 1) ? " — only this leg" : ""
        ["### #{covering.map { |leg| "`#{leg}`" }.join(", ")} (#{group.size})#{only}", "", list(group)]
      }]
  end

  def list(findings)
    return [] if findings.empty?

    findings.group_by(&:file).sort.map do |file, group|
      ["`#{file}`", "", group.map { |finding| "- L#{finding.line} — #{finding.label}#{source_suffix(finding)}" }, ""]
    end
  end

  def source_suffix(finding)
    source = finding.source.to_s.strip
    return "" if source.empty?

    ": `#{source}`"
  end
end
