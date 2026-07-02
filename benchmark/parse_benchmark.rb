#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duckling"
require "benchmark/ips"

# Measures Duckling.parse from Ruby (ips + GC/allocation pressure + threaded
# concurrency), including Magnus/Ruby conversion overhead that the upstream
# Rust-only Criterion benchmarks (wafer-inc/duckling's benches/parse.rs)
# explicitly exclude. Named DucklingBenchmark, not Duckling::Benchmark --
# `require "benchmark/ips"` defines top-level ::Benchmark, and nesting under
# Duckling::Benchmark would make a bare `Benchmark.ips` call resolve to this
# module instead of the stdlib one.
module DucklingBenchmark
  # Mirrors the upstream Rust Criterion corpus (wafer-inc/duckling's
  # benches/parse.rs) for direct comparability with those numbers.
  CORPUS = [
    {name: "short", input: "tomorrow at 3pm"},
    {name: "medium", input: "from 13 to 15 of July"},
    {name: "long", input: "meet me next Wednesday at 2:30pm for about 2 hours"},
    {name: "no_match", input: "the quick brown fox jumps over the lazy dog"},
    {name: "empty", input: ""}
  ].freeze

  GC_SAMPLE_ITERATIONS = 2_000
  THREAD_COUNT = 10
  CONCURRENCY_DURATION = 3 # seconds
  CONCURRENCY_SCENARIO = "medium"

  def self.run_ips
    report = ::Benchmark.ips do |x|
      x.config(time: 2, warmup: 1)
      CORPUS.each { |s| x.report(s[:name]) { Duckling.parse(s[:input], locale: "en") } }
      x.compare!
    end
    report.entries.each_with_object({}) do |entry, memo|
      memo[entry.label.to_sym] = {
        ips: entry.ips,
        ips_stddev_pct: entry.stats.error_percentage,
        iterations: entry.iterations,
        microseconds_per_call: entry.microseconds / entry.iterations.to_f
      }
    end
  end

  def self.measure_gc(text:)
    GC.start
    before = GC.stat
    GC_SAMPLE_ITERATIONS.times { Duckling.parse(text, locale: "en") }
    after = GC.stat
    {
      allocated_objects_per_call: (after[:total_allocated_objects] - before[:total_allocated_objects]) / GC_SAMPLE_ITERATIONS.to_f,
      minor_gc_count_delta: after[:minor_gc_count] - before[:minor_gc_count],
      major_gc_count_delta: after[:major_gc_count] - before[:major_gc_count]
    }
  end

  def self.throughput(thread_count:, text:, duration: CONCURRENCY_DURATION)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration
    threads = Array.new(thread_count) do
      Thread.new do
        n = 0
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          Duckling.parse(text, locale: "en")
          n += 1
        end
        n
      end
    end
    threads.sum(&:value) / duration.to_f
  end

  def self.run_concurrency
    text = CORPUS.find { |s| s[:name] == CONCURRENCY_SCENARIO }.fetch(:input)
    single = throughput(thread_count: 1, text: text)
    multi = throughput(thread_count: THREAD_COUNT, text: text)
    {
      thread_count: THREAD_COUNT,
      duration_seconds: CONCURRENCY_DURATION,
      scenario_input: CONCURRENCY_SCENARIO,
      single_thread_ops_per_sec: single,
      multi_thread_ops_per_sec: multi,
      scaling_factor: multi / single,
      efficiency_pct: (multi / single / THREAD_COUNT) * 100
    }
  end

  def self.run
    ips = run_ips
    scenarios = CORPUS.map do |s|
      {name: s[:name], input: s[:input]}
        .merge(ips.fetch(s[:name].to_sym))
        .merge(measure_gc(text: s[:input]))
    end
    {
      ruby_version: RUBY_VERSION,
      ruby_platform: RUBY_PLATFORM,
      rust_toolchain: `rustc --version`.strip,
      cargo_profile: ENV["RB_SYS_CARGO_PROFILE"] || "release",
      scenarios: scenarios,
      concurrency: run_concurrency
    }
  end
end

if __FILE__ == $0
  results = DucklingBenchmark.run
  # (Benchmark.ips already streamed its own human-readable console output
  # during run_ips, above -- this just adds the GC/concurrency summary.)
  puts "\nGC / allocation pressure (per call, sampled over #{DucklingBenchmark::GC_SAMPLE_ITERATIONS} iterations):"
  results[:scenarios].each do |s|
    puts format("  %-10s %8.1f objects/call  minor_gc=%d major_gc=%d",
      s[:name], s[:allocated_objects_per_call], s[:minor_gc_count_delta], s[:major_gc_count_delta])
  end
  c = results[:concurrency]
  puts "\nConcurrency (#{c[:thread_count]} threads x #{c[:duration_seconds]}s, #{c[:scenario_input]} input):"
  puts format("  single-thread: %.1f ops/sec", c[:single_thread_ops_per_sec])
  puts format("  %d-thread:     %.1f ops/sec  (%.2fx, %.1f%% of ideal linear scaling)",
    c[:thread_count], c[:multi_thread_ops_per_sec], c[:scaling_factor], c[:efficiency_pct])
end
