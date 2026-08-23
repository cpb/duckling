#!/usr/bin/env ruby
# Which TimeForm variant(s) does each EN rule construct, and which TimeData
# fields does it mutate? Read-only; safe to rerun.
require_relative "../../stage000-shared/crate"
require "json"

rules = Plan::Crate.new.rules
out = rules.map { |r| {name: r.name, line: r.line, builds: r.builds, mutates: r.mutates, items: r.items} }
File.write(File.join(__dir__, "out/rule_attribution.json"), JSON.pretty_generate(out) + "\n")

multi = rules.count { |r| r.builds.size > 1 }
none = rules.count { |r| r.builds.empty? }
puts "rules:                    #{rules.size}"
puts "construct >1 variant:     #{multi}   (why ownership needs a tiebreak)"
puts "construct no TimeForm:    #{none}   (the modifier slice)"
puts "wrote out/rule_attribution.json"
