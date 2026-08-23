#!/usr/bin/env ruby
# Creates the four corpus-growth tickets. Their content comes from the
# analysis stages, so a rerun after re-measuring updates them in place.
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
coverage = analysis("stage140-measure-corpus-coverage", "coverage.json")
branches = analysis("stage150-find-unexercised-branches", "unexercised_branches.json")
  .sort_by { |b| -b[:unexercised].size }

base = {parent: config.parent_issue, locale: config.locale,
        crate_name: config.crate_name, crate_version: config.crate_version,
        divergence_label: config.label(:divergence)}
labels = [config.label(:corpus)]

# The glob split is the prerequisite for the other three, so it goes first and
# its number is a local for them.
glob = Plan::GitHub.upsert(
  key: "corpus:glob-split",
  title: "Corpus: split local additions into a globbed directory so audits can run in parallel",
  body: renderer.render("glob_split.md.erb", **base),
  labels: labels + [config.label(:serial)], parent: config.parent_issue
)
puts "  glob-split          ##{glob}"

with_glob = base.merge(glob_split_issue: glob)

n = Plan::GitHub.upsert(
  key: "corpus:unexercised-branches",
  title: "Corpus: add cases for #{branches.sum { |b| b[:unexercised].size }} unexercised regex alternation branches",
  body: renderer.render("unexercised_branches.md.erb", **with_glob,
    branches: branches, rule_count: branches.size,
    total_branches: branches.sum { |b| b[:unexercised].size },
    corpus_size: Plan.config.corpus_cases.size),
  labels: labels, parent: config.parent_issue
)
puts "  unexercised-branches ##{n}"

unreached = coverage.select { |r| r[:unreached] }
n = Plan::GitHub.upsert(
  key: "corpus:unreached-rules",
  title: "Corpus: add cases for the #{unreached.size} rules no corpus case reaches at all",
  body: renderer.render("unreached_rules.md.erb", **with_glob, rules: unreached),
  labels: labels, parent: config.parent_issue
)
puts "  unreached-rules      ##{n}"

latent = Plan::Crate.new.rules.map(&:name).select { |name| name.to_s.include?("latent") }
n = Plan::GitHub.upsert(
  key: "corpus:with-latent",
  title: "Corpus: cover with_latent: and the 24 call sites #255 excluded",
  body: renderer.render("with_latent.md.erb", **with_glob,
    latent_rules: latent, modifier_issue: Plan::Ledger.fetch("slice:Modifiers")),
  labels: labels + [config.label(:test_first)], parent: config.parent_issue
)
puts "  with-latent          ##{n}"
