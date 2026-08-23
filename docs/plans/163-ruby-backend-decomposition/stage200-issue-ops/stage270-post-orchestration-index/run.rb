#!/usr/bin/env ruby
# Posts (or updates) the orchestration index comment on the parent issue.
# Idempotent through an HTML marker, since GitHub has no comment upsert.
require_relative "../../stage000-shared/slices"
require_relative "../../stage000-shared/github"
require_relative "../../stage000-shared/renderer"
require_relative "../../stage000-shared/ledger"

MARKER = "duckling-plan:orchestration-index"

config = Plan.config
renderer = Plan::Renderer.new(__dir__)
ids = Plan::Ledger.all
slices = Plan::SliceSet.new.to_a
crate = Plan::Crate.new

rows = slices.sort_by { |s| [s.wave, -s.rules.size, s.key] }.map do |s|
  key = s.dimension? ? "dimension:#{s.key}" : "slice:#{s.key}"
  {name: s.dimension? ? "#{s.key} (dim)" : "`#{s.key}`", wave: s.wave, rules: s.rules.size,
   port: ids.fetch(key), audit: ids.fetch("audit:#{s.key}")}
end

body = renderer.render("orchestration_index.md.erb",
  crate_name: config.crate_name, crate_version: config.crate_version,
  total_issues: ids.size, slice_count: slices.size, ids: ids, rows: rows,
  modifier_rules: slices.find(&:modifiers?).rules.size,
  multi_variant: crate.rules.count { |r| r.builds.size > 1 })

Plan::GitHub.upsert_comment(config.parent_issue, MARKER, body)
puts "index comment #{Plan::GitHub.dry_run? ? "rendered" : "posted"} on ##{config.parent_issue}"
