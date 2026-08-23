#!/usr/bin/env ruby
# Creates the three issues that gate everything else: the engine spine, the
# ranking layer, and fixture capture. Order matters — each references the
# number of the one before it.
require_relative "../../stage000-shared/config"
require_relative "../../stage000-shared/github"
require_relative "../../stage000-shared/renderer"
require_relative "../../stage000-shared/ledger"

config = Plan.config
renderer = Plan::Renderer.new(__dir__)
base = {parent: config.parent_issue, locale: config.locale,
        crate_name: config.crate_name, crate_version: config.crate_version}
labels = [config.label(:umbrella), config.label(:spine), config.label(:serial), config.label(:test_first)]

spine = Plan::GitHub.upsert(
  key: "phase0:spine",
  title: "Ruby backend Phase 0 — engine spine, backend switch, base classes, fixture format",
  body: renderer.render("phase0_spine.md.erb", **base),
  labels: labels, parent: config.parent_issue
)
puts "  spine            ##{spine}"

ranking = Plan::GitHub.upsert(
  key: "phase0:ranking",
  title: "Ruby backend — port the ranking layer and load the upstream trained classifiers",
  body: renderer.render("ranking_layer.md.erb", **base, spine_issue: spine),
  labels: labels, parent: config.parent_issue
)
puts "  ranking          ##{ranking}"

# Fixture capture names the whole corpus stage as its gate. Those issues may
# not exist yet on a first run, so their numbers fall back to a placeholder
# and a rerun of this stage fills them in.
def later(key) = Plan::Ledger[key] || "TBD"

capture = Plan::GitHub.upsert(
  key: "phase1:fixture-capture",
  title: "Ruby backend Phase 1 — fixture capture script, bucketed by slice",
  body: renderer.render("phase1_fixture_capture.md.erb", **base,
    spine_issue: spine,
    glob_split_issue: later("corpus:glob-split"),
    branches_issue: later("corpus:unexercised-branches"),
    unreached_issue: later("corpus:unreached-rules"),
    latent_issue: later("corpus:with-latent"),
    audit_parent_issue: later("audit:parent")),
  labels: [config.label(:umbrella), config.label(:fixture_capture), config.label(:serial)],
  parent: config.parent_issue
)
puts "  fixture-capture  ##{capture}"
puts "\nRerun this stage after stage240/stage250 to fill in the corpus-stage gate numbers."
