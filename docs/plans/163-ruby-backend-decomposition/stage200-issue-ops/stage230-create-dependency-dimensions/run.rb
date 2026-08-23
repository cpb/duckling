#!/usr/bin/env ruby
# Creates one issue per dependency dimension (numeral, duration, ordinal,
# time_grain). Idempotent through the ledger.
require_relative "../../stage000-shared/slices"
require_relative "../../stage000-shared/github"
require_relative "../../stage000-shared/renderer"
require_relative "../../stage000-shared/ledger"
require "yaml"

config = Plan.config
notes = YAML.safe_load_file(File.join(__dir__, "dimensions.yml"))
renderer = Plan::Renderer.new(__dir__)

Plan::SliceSet.new.select(&:dimension?).each do |slice|
  note = notes.fetch(slice.key)
  body = renderer.render("dependency_dimension.md.erb",
    parent: config.parent_issue, locale: config.locale,
    crate_name: config.crate_name, crate_version: config.crate_version,
    spine_issue: Plan::Ledger.fetch("phase0:spine"),
    fixture_capture_issue: Plan::Ledger.fetch("phase1:fixture-capture"),
    divergence_label: config.label(:divergence),
    slice: slice, note: note.fetch("note"), corpus: note.fetch("corpus"))

  number = Plan::GitHub.upsert(
    key: "dimension:#{slice.key}",
    title: "Ruby backend Wave A — #{slice.key.tr("_", "-")} dimension (#{slice.rules.size} EN rules)",
    body: body,
    labels: [config.label(:umbrella), config.label(:waves, "A"), config.label(:test_first)],
    parent: config.parent_issue
  )
  puts format("  %-12s #%d  (%d rules)", slice.key, number, slice.rules.size)
end
