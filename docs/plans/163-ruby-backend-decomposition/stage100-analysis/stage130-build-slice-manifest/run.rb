#!/usr/bin/env ruby
# The manifest every issue-ops stage renders from: one entry per slice, with
# its wave, its Rust excerpt, its resolver reference count and its rules.
# Read-only; safe to rerun.
require_relative "../../stage000-shared/slices"
require "json"

slices = Plan::SliceSet.new.map do |s|
  {key: s.key, slug: s.slug, wave: s.wave, kind: s.kind, excerpt: s.excerpt,
   resolver_refs: s.resolver_refs,
   rules: s.rules.map { |r| {name: r.name, line: r.line, mutates: r.mutates} }}
end
File.write(File.join(__dir__, "out/slices.json"), JSON.pretty_generate(slices) + "\n")

by_wave = slices.group_by { |s| s[:wave] }.transform_values(&:size)
puts "slices: #{slices.size}   by wave: #{by_wave.sort.to_h}"
puts "heaviest: " + slices.sort_by { |s| -s[:rules].size }.first(4).map { |s| "#{s[:key]}=#{s[:rules].size}" }.join(" ")
puts "wrote out/slices.json"
