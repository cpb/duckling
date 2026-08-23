#!/usr/bin/env ruby
# Attribute every measured gap to the slice that owns the rule, so each slice
# issue can carry its own findings and no two agents chase the same one.
# Read-only; safe to rerun. Issue numbers are added when the ledger has them.
require_relative "../../stage000-shared/slices"
require_relative "../../stage000-shared/ledger"
require "json"

def load(stage, file)
  path = File.join(__dir__, "..", stage, "out", file)
  abort "Run #{stage} first — #{file} missing." unless File.exist?(path)
  JSON.parse(File.read(path), symbolize_names: true)
end

coverage = load("stage140-measure-corpus-coverage", "coverage.json")
branches = load("stage150-find-unexercised-branches", "unexercised_branches.json")

set = Plan::SliceSet.new
owner_by_line = {}
set.each { |s|
  next if s.dimension?
  s.rules.each { |r| owner_by_line[r.line] = s.key }
}
branch_by_rule = branches.to_h { |b| [[b[:dimension], b[:line]], b[:unexercised]] }

gaps = Hash.new { |h, k| h[k] = {unreached: [], opaque: [], branches: {}} }
coverage.each do |rule|
  slice = (rule[:dimension] == "time") ? owner_by_line.fetch(rule[:line], "??") : rule[:dimension]
  gaps[slice][:unreached] << rule[:name] if rule[:unreached]
  gaps[slice][:opaque] << rule[:name] if rule[:opaque]
  if (b = branch_by_rule[[rule[:dimension], rule[:line]]])
    gaps[slice][:branches][rule[:name]] = b
  end
end

report = set.map do |s|
  g = gaps[s.key]
  branch_count = g[:branches].values.sum(&:size)
  {slice: s.key, slug: s.slug, wave: s.wave,
   issue: Plan::Ledger["slice:#{s.key}"], audit_issue: Plan::Ledger["audit:#{s.key}"],
   unreached: g[:unreached], opaque: g[:opaque], branches: g[:branches],
   # Ranking only, for deciding where to look first. Weights are a judgement
   # call, not a measurement: an unreached rule is worse than a branch, and an
   # opaque rule is worse still because nothing automated can check it.
   severity: g[:unreached].size * 3 + branch_count + g[:opaque].size * 4}
end.sort_by { |r| -r[:severity] }

File.write(File.join(__dir__, "out/gaps_by_slice.json"), JSON.pretty_generate(report) + "\n")

clean = report.count { |r| r[:severity].zero? }
puts "slices with a detected gap: #{report.size - clean} of #{report.size}"
puts
puts "SLICE          WAVE   unreach branches  opaque"
report.reject { |r| r[:severity].zero? }.each do |r|
  puts format("%-14s %-5s %8d %8d %7d", r[:slice], r[:wave], r[:unreached].size,
    r[:branches].values.sum(&:size), r[:opaque].size)
end
puts "\nwrote out/gaps_by_slice.json"
