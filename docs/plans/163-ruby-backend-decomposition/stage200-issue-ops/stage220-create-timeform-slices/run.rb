#!/usr/bin/env ruby
# Creates one issue per TimeForm variant, plus the modifier slice.
# Idempotent: reruns edit the issues recorded in ../../issue-ledger.json.
require_relative "../../stage000-shared/slices"
require_relative "../../stage000-shared/github"
require_relative "../../stage000-shared/renderer"
require_relative "../../stage000-shared/ledger"
require "yaml"

config = Plan.config
notes = YAML.safe_load_file(File.join(__dir__, "notes.yml"))
renderer = Plan::Renderer.new(__dir__)

common = {
  parent: config.parent_issue,
  locale: config.locale,
  crate_name: config.crate_name,
  crate_version: config.crate_version,
  spine_issue: Plan::Ledger.fetch("phase0:spine"),
  ranking_issue: Plan::Ledger.fetch("phase0:ranking"),
  fixture_capture_issue: Plan::Ledger.fetch("phase1:fixture-capture"),
  divergence_label: config.label(:divergence)
}

Plan::SliceSet.new.reject(&:dimension?).each do |slice|
  template = slice.modifiers? ? "modifier_slice.md.erb" : "time_form_slice.md.erb"
  body = renderer.render(template, **common,
    slice: slice,
    wave_note: notes.fetch("wave_notes").fetch(slice.wave),
    sizing_note: notes.fetch("sizing")[slice.key])

  title = if slice.modifiers?
    "Ruby backend Wave A — modifier and absorption rules (#{slice.rules.size} EN rules, no TimeForm of their own)"
  else
    "Ruby backend Wave #{slice.wave} — TimeForm::#{slice.key} (#{slice.rules.size} EN rule#{"s" unless slice.rules.size == 1})"
  end

  number = Plan::GitHub.upsert(
    key: "slice:#{slice.key}", title: title, body: body,
    labels: [config.label(:umbrella), config.label(:waves, slice.wave), config.label(:test_first)],
    parent: config.parent_issue
  )
  puts format("  %-20s #%d  (%d rules)", slice.key, number, slice.rules.size)
end
