#!/usr/bin/env ruby
# Apply the highest-wave-wins tiebreak so every rule has exactly one owner.
# Read-only; safe to rerun.
require_relative "../../stage000-shared/slices"
require "json"

set = Plan::SliceSet.new
owned = set.ownership.transform_values { |rs| rs.map { |r| {name: r.name, line: r.line} } }
File.write(File.join(__dir__, "out/ownership.json"), JSON.pretty_generate(owned) + "\n")

lines = owned.values.flatten.map { |r| r[:line] }
abort "FAIL: #{(lines - lines.uniq).size} rules owned twice" unless lines.size == lines.uniq.size
puts "owners:  #{owned.size}"
puts "rules:   #{lines.size}  (each owned exactly once)"
owned.sort_by { |_, rs| -rs.size }.first(5).each { |k, rs| puts "  #{k.ljust(12)} #{rs.size}" }
puts "wrote out/ownership.json"
