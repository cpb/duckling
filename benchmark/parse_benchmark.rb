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
  # Realistic multi-date prose (18 time entities), from PR #53's
  # bin/benchmark_parse -- stress-tests allocation/timing scaling with
  # entity *count* per call, not just per-entity shape, since the
  # conversion layer runs once per extracted Entity.
  CAMPING_TRIP_EMAIL = <<~EMAIL
    Hey everyone,

    Wanted to loop you all in on our camping trip planning for the summer --
    we've got a few weekends to lock down. First up, we're thinking Yosemite
    from June 12th to June 15th, weather permitting; if that valley is too
    crowded we could push it to June 19th instead. Then in July, maybe the
    second week, say July 8th through July 12th, we could head down to Big Sur
    along the coast -- I know a few of you can't make it until July 10th, so
    we might just meet everyone there by lunchtime that day.

    August is looking busy but I think the weekend of August 22nd to August
    24th would work for a shorter trip up to the Sierras, and if the weather
    holds we could extend it to August 25th. Let's also pencil in Labor Day
    weekend, August 29th through September 1st, for one last trip before
    school starts back up on September 3rd. If anyone's free the week before,
    say September 2nd, we could even sneak in a day hike.

    Reply by next Friday if any of these dates don't work for you, and we'll
    finalize the full schedule by the end of the month. Looking forward to
    seeing everyone out there!
  EMAIL

  # Mirrors the upstream Rust Criterion corpus (wafer-inc/duckling's
  # benches/parse.rs) for direct comparability with those numbers, plus
  # CAMPING_TRIP_EMAIL for realistic long-prose, multi-entity input.
  CORPUS = [
    {name: "short", input: "tomorrow at 3pm"},
    {name: "medium", input: "from 13 to 15 of July"},
    {name: "long", input: "meet me next Wednesday at 2:30pm for about 2 hours"},
    {name: "no_match", input: "the quick brown fox jumps over the lazy dog"},
    {name: "empty", input: ""},
    {name: "camping_trip_email", input: CAMPING_TRIP_EMAIL}
  ].freeze

  GC_SAMPLE_ITERATIONS = 2_000
  # camping_trip_email is ~550ms/call (long multi-entity prose, per PR #53's
  # own measurement) -- 2000 iterations at that cost would take ~18 minutes.
  # Sample it far fewer times; still gives a directionally useful per-call
  # estimate without blowing up the suite's total runtime.
  GC_SAMPLE_ITERATIONS_OVERRIDES = {"camping_trip_email" => 20}.freeze
  THREAD_COUNT = 10
  CONCURRENCY_DURATION = 3 # seconds
  CONCURRENCY_SCENARIO = "medium"

  # Suffix used to key the native (no-thread) dispatch variant's ips.report
  # label alongside each scenario's normal (thread-per-call) entry, so a
  # single Benchmark.ips run produces both without a second warmup/measure
  # pass (issue #64's dispatch-overhead comparison).
  NATIVE_LABEL_SUFFIX = "_native"

  def self.run_ips
    report = ::Benchmark.ips do |x|
      x.config(time: 2, warmup: 1)
      CORPUS.each { |s| x.report(s[:name]) { Duckling.parse(s[:input], locale: "en") } }
      CORPUS.each { |s| x.report("#{s[:name]}#{NATIVE_LABEL_SUFFIX}") { Duckling::Native.parse(s[:input], locale: "en") } }
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

  # Measures Native.parse, not Duckling.parse: the allocated_objects/GC
  # columns describe what a *parse* costs, and Duckling.parse's
  # thread-per-call dispatch (issue #64) drowns that signal in Thread
  # allocation churn — each spawned Thread brings its own object plus stack
  # /bookkeeping allocations and drives minor GC hard (observed: objects/call
  # 28 -> 35 and minor GC 1 -> 62 across a recording when this loop went
  # through Duckling.parse). Dispatch overhead is reported separately by the
  # ips dispatch-mode comparison; keeping this loop on Native.parse also
  # keeps these columns comparable with entries recorded before #64.
  def self.measure_gc(name:, text:)
    iterations = GC_SAMPLE_ITERATIONS_OVERRIDES.fetch(name, GC_SAMPLE_ITERATIONS)
    GC.start
    before = GC.stat
    iterations.times { Duckling::Native.parse(text, locale: "en") }
    after = GC.stat
    {
      allocated_objects_per_call: (after[:total_allocated_objects] - before[:total_allocated_objects]) / iterations.to_f,
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
      thread_stats = ips.fetch(s[:name].to_sym)
      native_stats = ips.fetch(:"#{s[:name]}#{NATIVE_LABEL_SUFFIX}")
      overhead_pct = ((thread_stats[:microseconds_per_call] - native_stats[:microseconds_per_call]) /
        native_stats[:microseconds_per_call]) * 100

      {name: s[:name], input: s[:input]}
        .merge(thread_stats)
        .merge(measure_gc(name: s[:name], text: s[:input]))
        .merge(
          native_ips: native_stats[:ips],
          native_microseconds_per_call: native_stats[:microseconds_per_call],
          thread_overhead_pct: overhead_pct
        )
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
  puts "\nGC / allocation pressure (per call, sample size varies by scenario -- see GC_SAMPLE_ITERATIONS_OVERRIDES):"
  results[:scenarios].each do |s|
    iterations = DucklingBenchmark::GC_SAMPLE_ITERATIONS_OVERRIDES.fetch(s[:name], DucklingBenchmark::GC_SAMPLE_ITERATIONS)
    puts format("  %-20s %8.1f objects/call  minor_gc=%d major_gc=%d  (n=%d)",
      s[:name], s[:allocated_objects_per_call], s[:minor_gc_count_delta], s[:major_gc_count_delta], iterations)
  end
  c = results[:concurrency]
  puts "\nConcurrency (#{c[:thread_count]} threads x #{c[:duration_seconds]}s, #{c[:scenario_input]} input):"
  puts format("  single-thread: %.1f ops/sec", c[:single_thread_ops_per_sec])
  puts format("  %d-thread:     %.1f ops/sec  (%.2fx, %.1f%% of ideal linear scaling)",
    c[:thread_count], c[:multi_thread_ops_per_sec], c[:scaling_factor], c[:efficiency_pct])
end
