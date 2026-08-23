#!/usr/bin/env ruby
# Creates the three reduce issues. Strictly serial: parity, then measurement,
# then the forecast — decision 6 of #163 says the gate is parity, so the
# measurement issue must not be startable before the CI one closes.
require_relative "../../stage000-shared/slices"
require_relative "../../stage000-shared/github"
require_relative "../../stage000-shared/renderer"
require_relative "../../stage000-shared/ledger"

config = Plan.config
renderer = Plan::Renderer.new(__dir__)
labels = [config.label(:umbrella), config.label(:reduce)]
base = {parent: config.parent_issue, locale: config.locale}

ci = Plan::GitHub.upsert(
  key: "reduce:ci",
  title: "Ruby backend Phase 4 — run the full corpus against both backends in CI",
  body: renderer.render("reduce_ci.md.erb", **base,
    audit_parent_issue: Plan::Ledger["audit:parent"] || "TBD",
    corpus_size: config.corpus_cases.size),
  labels: labels, parent: config.parent_issue
)
puts "  ci        ##{ci}"

measure = Plan::GitHub.upsert(
  key: "reduce:measure",
  title: "Ruby backend Phase 4 — measure memory and throughput with PR #162's harness",
  body: renderer.render("reduce_measure.md.erb", **base, reduce_ci_issue: ci),
  labels: labels, parent: config.parent_issue
)
puts "  measure   ##{measure}"

forecast = Plan::GitHub.upsert(
  key: "reduce:forecast",
  title: "Ruby backend Phase 4 — publish the go/no-go forecast for the remaining 26 locales",
  body: renderer.render("reduce_forecast.md.erb", **base,
    reduce_measure_issue: measure, slice_count: Plan::SliceSet.new.count),
  labels: labels + ["documentation"], parent: config.parent_issue
)
puts "  forecast  ##{forecast}"
