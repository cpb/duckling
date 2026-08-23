#!/usr/bin/env ruby
# Creates the audit parent and one audit issue per slice. Each carries its own
# pre-identified gaps from stage160, so no two agents chase the same finding.
require_relative "../../stage000-shared/slices"
require_relative "../../stage000-shared/github"
require_relative "../../stage000-shared/renderer"
require_relative "../../stage000-shared/ledger"
require "json"

ANALYSIS = File.expand_path("../../stage100-analysis", __dir__)
def analysis(stage, file)
  path = File.join(ANALYSIS, stage, "out", file)
  abort "Run stage100-analysis/#{stage} first." unless File.exist?(path)
  JSON.parse(File.read(path), symbolize_names: true)
end

config = Plan.config
renderer = Plan::Renderer.new(__dir__)
gaps = analysis("stage160-join-gaps-to-slices", "gaps_by_slice.json").to_h { |g| [g[:slice], g] }
coverage = analysis("stage140-measure-corpus-coverage", "coverage.json")
branches = analysis("stage150-find-unexercised-branches", "unexercised_branches.json")
slices = Plan::SliceSet.new.to_a

base = {parent: config.parent_issue, divergence_label: config.label(:divergence),
        glob_split_issue: Plan::Ledger.fetch("corpus:glob-split"),
        spine_issue: Plan::Ledger.fetch("phase0:spine"),
        fixture_capture_issue: Plan::Ledger.fetch("phase1:fixture-capture")}

parent = Plan::GitHub.upsert(
  key: "audit:parent",
  title: "Corpus audit — #{slices.size} slices, before the Ruby port (was Phase 3)",
  body: renderer.render("audit_parent.md.erb", **base,
    slice_count: slices.size, corpus_size: config.corpus_cases.size,
    total_branches: branches.sum { |b| b[:unexercised].size }, branch_rules: branches.size,
    unreached: coverage.count { |r| r[:unreached] }, opaque: coverage.count { |r| r[:opaque] },
    reduce_ci_issue: Plan::Ledger.fetch("reduce:ci")),
  labels: [config.label(:umbrella), config.label(:corpus_audit)], parent: config.parent_issue
)
puts "  parent  ##{parent}"

# Where to read, per slice kind. Line numbers are given here and withheld from
# the Phase 2 issues on purpose: this is the phase that reads the source.
def reading_list(slice)
  return "`src/dimensions/#{slice.slug}/en.rs` and `src/dimensions/#{slice.slug}/mod.rs` in full" if slice.dimension?
  lines = slice.rules.map(&:line).sort
  if slice.modifiers?
    "the #{slice.rules.size} modifier rules in `src/dimensions/time/en.rs` at lines #{lines.join(", ")}, " \
      "plus every place `src/dimensions/time/mod.rs` reads `latent`, `early_late`, " \
      "`open_interval_direction`, `timezone` or `direction` during resolution"
  elsif lines.empty?
    "`grep -n 'TimeForm::#{slice.key}' src/dimensions/time/mod.rs` (#{slice.resolver_refs} references) — " \
      "this variant has no rules of its own, so the whole audit is the resolver"
  else
    "the #{slice.rules.size} rule#{"s" unless slice.rules.size == 1} in `src/dimensions/time/en.rs` at " \
      "line#{"s" unless lines.size == 1} #{lines.join(", ")}, plus every `TimeForm::#{slice.key}` reference " \
      "in `src/dimensions/time/mod.rs` (#{slice.resolver_refs}: `grep -n 'TimeForm::#{slice.key}' src/dimensions/time/mod.rs`)"
  end
end

# Pre-identified findings, grouped so an agent can see at a glance what is
# already ticketed elsewhere versus what is theirs to discover.
def known_blocks(gap, ledger)
  return [] unless gap
  out = []
  unless gap[:branches].empty?
    rows = gap[:branches].map { |name, list| "- `#{name.to_s.gsub("|", "\\|")}` → #{list.join(" · ")}" }
    out << "**Unexercised alternation branches — already ticketed in ##{ledger["corpus:unexercised-branches"]}, " \
            "do not duplicate:**\n\n#{rows.join("\n")}"
  end
  unless gap[:unreached].empty?
    out << "**Rules no corpus case reaches — already ticketed in ##{ledger["corpus:unreached-rules"]}, " \
            "do not duplicate:**\n\n#{gap[:unreached].map { |n| "- `#{n.gsub("|", "\\|")}`" }.join("\n")}"
  end
  unless gap[:opaque].empty?
    out << "**Rules the sweep cannot measure — THIS IS YOUR PRIMARY TARGET.** These have no regex item " \
            "(pure `predicate`/`dim` composition), so no automated method can tell whether the corpus " \
            "exercises them. Only reading the Rust can:\n\n" +
      gap[:opaque].map { |n| "- `#{n.gsub("|", "\\|")}`" }.join("\n")
  end
  out
end

ledger = Plan::Ledger.all
slices.each do |slice|
  number = Plan::GitHub.upsert(
    key: "audit:#{slice.key}",
    title: "Corpus audit: #{slice.label}",
    body: renderer.render("audit_slice.md.erb", **base,
      audit_parent_issue: parent, slug: slice.slug, dimension: slice.dimension?,
      sibling_count: slices.size - 1, reading_list: reading_list(slice),
      known: known_blocks(gaps[slice.key.to_sym], ledger),
      port_issue: Plan::Ledger.fetch(slice.dimension? ? "dimension:#{slice.key}" : "slice:#{slice.key}")),
    labels: [config.label(:umbrella), config.label(:corpus_audit)], parent: parent
  )
  puts format("  %-20s #%d", slice.key, number)
end
