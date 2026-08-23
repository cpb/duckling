#!/usr/bin/env ruby
# Finer than stage140: a rule the corpus reaches can still have alternation
# branches it never walks. `(mon|tue|...|sun)` is one pattern and seven paths.
# Read-only; safe to rerun.
require_relative "../../stage000-shared/crate"
require "json"

COVERAGE = File.join(__dir__, "../stage140-measure-corpus-coverage/out/coverage.json")
abort "Run stage140 first — #{COVERAGE} missing." unless File.exist?(COVERAGE)

# Only literal branches are testable this way. A branch that is itself regex
# (`\d{1,2}`) says nothing about coverage by being absent from the corpus.
LITERAL = /\A[a-z0-9 .'-]+\z/i

# Split on `|` at depth zero, respecting escapes, groups and character classes.
def split_alternation(source)
  parts = []
  current = +""
  depth = 0
  in_class = false
  escaped = false
  source.each_char do |ch|
    if escaped
      current << ch
      escaped = false
      next
    end
    case ch
    when "\\" then current << ch
                   escaped = true
    when "[" then in_class = true
                  current << ch
    when "]" then in_class = false
                  current << ch
    when "(" then depth += 1 unless in_class
                  current << ch
    when ")" then depth -= 1 unless in_class
                  current << ch
    when "|"
      if depth.zero? && !in_class then parts << current
                                       current = +"" else current << ch
      end
    else current << ch
    end
  end
  parts << current
end

# Every alternation in the pattern: inside each group, and across the whole.
def branches(pattern)
  found = []
  stack = []
  in_class = false
  i = 0
  while i < pattern.length
    ch = pattern[i]
    if ch == "\\" then i += 2
                       next
    end
    in_class = true if ch == "[" && !in_class
    in_class = false if ch == "]" && in_class
    unless in_class
      if ch == "(" then stack << i
      elsif ch == ")" && !stack.empty?
        body = pattern[(stack.pop + 1)...i]
          .sub(/\A\?:/, "").sub(/\A\?P?<[^>]*>/, "").sub(/\A\?[imsx-]*:/, "")
        parts = split_alternation(body)
        found.concat(parts) if parts.size > 1
      end
    end
    i += 1
  end
  top = split_alternation(pattern)
  found.concat(top) if top.size > 1
  found
end

texts = Plan.config.corpus_cases.map { |c| c["text"] }.compact.map(&:downcase)
report = JSON.parse(File.read(COVERAGE), symbolize_names: true).filter_map do |rule|
  missing = rule[:patterns].flat_map { |p| branches(p[:pattern]) }
    .map(&:strip).select { |b| b.length >= 2 && b.match?(LITERAL) }
    .reject { |b| texts.any? { |t| t.match?(/#{Regexp.escape(b)}/i) } }
    .uniq
  next if missing.empty?
  {dimension: rule[:dimension], name: rule[:name], line: rule[:line], unexercised: missing}
end

File.write(File.join(__dir__, "out/unexercised_branches.json"), JSON.pretty_generate(report) + "\n")
total = report.sum { |r| r[:unexercised].size }
puts "rules with >=1 unexercised literal branch: #{report.size}"
puts "unexercised branches:                      #{total}"
report.group_by { |r| r[:dimension] }.each { |d, rs| puts "  #{d.ljust(11)} #{rs.sum { |r| r[:unexercised].size }}" }
puts "wrote out/unexercised_branches.json"
