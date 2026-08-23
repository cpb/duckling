#!/usr/bin/env ruby
# Translate every rule regex to Ruby and test it against every corpus text.
# Answers two questions: does the dialect translate at all, and which rules
# does the corpus never reach? Read-only; safe to rerun.
require_relative "../../stage000-shared/slices"
require "json"

crate = Plan::Crate.new
cases = Plan.config.corpus_cases
all_texts = cases.map { |c| c["text"] }.compact
time_texts = cases
  .select { |c| c["file"].to_s.start_with?("time") || c["check"].to_s.include?("time") }
  .map { |c| c["text"] }.compact

sources = {"time" => [crate.time_en, time_texts]}
Plan.config.dependency_dimensions.each do |dim|
  # time_grain has no corpus file of its own: grain is asserted as the second
  # argument of every time case, so its texts are the time texts.
  texts = (dim == "time_grain") ? time_texts : cases.select { |c| c["file"].to_s.include?(dim) }.map { |c| c["text"] }.compact
  sources[dim] = [crate.dimension_en(dim), texts.empty? ? all_texts : texts]
end

results = sources.flat_map do |dimension, (file, texts)|
  crate.rules(file).map do |rule|
    per_pattern = rule.patterns.map do |pattern|
      rx = Plan::RustRegex.to_ruby(pattern)
      {pattern: pattern, hits: texts.count { |t| rx.match?(t) }, error: nil}
    rescue ArgumentError => e
      {pattern: pattern, hits: 0, error: e.message}
    end
    {dimension: dimension, name: rule.name, line: rule.line, items: rule.items,
     patterns: per_pattern,
     untranslatable: per_pattern.any? { |p| p[:error] },
     unreached: !per_pattern.empty? && per_pattern.all? { |p| p[:hits].zero? },
     opaque: rule.patterns.empty?}
  end
end

File.write(File.join(__dir__, "out/coverage.json"), JSON.pretty_generate(results) + "\n")

puts "corpus texts:   #{all_texts.size} total, #{time_texts.size} time"
puts "rules measured: #{results.size}"
puts "untranslatable: #{results.count { |r| r[:untranslatable] }}   <- decision 5's risk, measured"
puts "unreached:      #{results.count { |r| r[:unreached] }}"
puts "opaque:         #{results.count { |r| r[:opaque] }}   (no regex item; sweep cannot see these)"
puts "wrote out/coverage.json"
