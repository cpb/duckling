#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "parse_benchmark"
require "json"
require "fileutils"

module DucklingBenchmark
  # Detects which environment a benchmark ran in, records results as JSON
  # under docs/benchmarks/<environment>/<version>.json, and regenerates
  # docs/benchmarks/README.md from the full history. Deliberately has no
  # knowledge of git/gh -- that lives in the Rakefile's benchmark:record_pr
  # task, keeping this module a pure "compute + write files" unit that's
  # easy to test.
  module Report
    DEFAULT_DOCS_DIR = File.expand_path("../docs/benchmarks", __dir__)
    DEFAULT_DOCS_README_PATH = File.join(DEFAULT_DOCS_DIR, "README.md")

    ENVIRONMENT_ORDER = %w[github-actions claude-code-web local].freeze
    CHART_EXCLUDED_SCENARIOS = %w[camping_trip_email].freeze

    def self.detect_environment(env = ENV)
      if env["GITHUB_ACTIONS"] == "true"
        "github-actions"
      elsif env["CLAUDE_CODE_REMOTE"] == "true"
        "claude-code-web"
      else
        "local"
      end
    end

    ENVIRONMENT = detect_environment

    def self.write_json(environment:, version:, results:, dir: DEFAULT_DOCS_DIR)
      env_dir = File.join(dir, environment)
      FileUtils.mkdir_p(env_dir)
      payload = results.merge(environment: environment, version: version, date: Time.now.utc.strftime("%Y-%m-%d"))
      File.write(File.join(env_dir, "#{version}.json"), JSON.pretty_generate(payload))
      payload
    end

    def self.history(dir: DEFAULT_DOCS_DIR)
      Dir.glob(File.join(dir, "*", "*.json")).map do |f|
        JSON.parse(File.read(f), symbolize_names: true)
      end
    end

    def self.latest_per_environment(history)
      history.group_by { |e| e[:environment] }.transform_values do |entries|
        entries.max_by { |e| Gem::Version.new(e[:version]) }
      end
    end

    def self.sorted_environments(names)
      names.sort_by { |n| [ENVIRONMENT_ORDER.index(n) || ENVIRONMENT_ORDER.size, n] }
    end

    def self.build_results_table(latest)
      return "_No benchmark data recorded yet — run `bin/benchmark record-pr` to add the first entry._\n" if latest.empty?

      lines = []
      sorted_environments(latest.keys).each do |env|
        entry = latest.fetch(env)
        lines << "### #{env} (v#{entry[:version]}, #{entry[:date]})"
        lines << ""
        lines << "Ruby #{entry[:ruby_version]} (#{entry[:ruby_platform]}), #{entry[:rust_toolchain]}, `#{entry[:cargo_profile]}` profile."
        lines << ""
        lines << "| Scenario | ips | µs/call | objects/call | minor GC | major GC |"
        lines << "|---|---|---|---|---|---|"
        entry[:scenarios].each do |s|
          lines << format("| %s | %.1f | %.1f | %.1f | %d | %d |",
            s[:name], s[:ips], s[:microseconds_per_call], s[:allocated_objects_per_call],
            s[:minor_gc_count_delta], s[:major_gc_count_delta])
        end
        lines << ""
        c = entry[:concurrency]
        lines << format("%d-thread throughput: %.1f ops/sec vs %.1f ops/sec single-threaded (%.2fx, %.1f%% of ideal linear scaling).",
          c[:thread_count], c[:multi_thread_ops_per_sec], c[:single_thread_ops_per_sec], c[:scaling_factor], c[:efficiency_pct])
        lines << ""
        dispatch_section = build_dispatch_section(entry)
        lines << dispatch_section unless dispatch_section.empty?
      end
      lines.join("\n")
    end

    # Compares Duckling::Native.parse (no thread spawn) against Duckling.parse
    # (thread-per-call dispatch, measured under an active Fiber scheduler --
    # see run_ips) for a single environment's latest run. Recorded entries
    # from before this schema existed have no
    # `native_ips`/`native_microseconds_per_call`/`thread_overhead_pct` fields
    # -- returns "" for those rather than raising, so this stays purely
    # additive and environments upgrade to the new schema independently as
    # each one's next `benchmark:record_pr` run lands.
    def self.build_dispatch_section(entry)
      scenarios = entry[:scenarios].select { |s| s[:native_ips] }
      return "" if scenarios.empty?

      lines = ["#### Dispatch overhead: native vs thread-per-call (#{entry[:environment]} v#{entry[:version]})", ""]
      lines << "Thread-per-call is `Duckling.parse` measured with a Fiber scheduler installed " \
        "(the only condition under which it spawns a background `Thread`, so a calling Fiber " \
        "can yield to its Async::Reactor while the native call runs); native is " \
        "`Duckling::Native.parse` (no thread). Without a Fiber scheduler -- a plain Puma/Sidekiq " \
        "thread pool -- `Duckling.parse` already takes the same fast path as native, paying none " \
        "of this overhead. Overhead is a fixed per-call cost, not a throughput loss -- negligible " \
        "against slower scenarios, a real multiplier against the fastest ones."
      lines << ""
      lines << "| Scenario | ips (native) | ips (thread-per-call) | µs/call (native) | µs/call (thread-per-call) | overhead |"
      lines << "|---|---|---|---|---|---|"
      scenarios.each do |s|
        lines << format("| %s | %.1f | %.1f | %.1f | %.1f | %.1f%% |",
          s[:name], s[:native_ips], s[:ips], s[:native_microseconds_per_call], s[:microseconds_per_call], s[:thread_overhead_pct])
      end
      lines << ""

      chartable = scenarios.reject { |s| CHART_EXCLUDED_SCENARIOS.include?(s[:name]) }
      unless chartable.empty?
        scenario_names = chartable.map { |s| s[:name] }
        lines << "```mermaid"
        lines << "xychart-beta"
        lines << %(    title "#{entry[:environment]} v#{entry[:version]}: native vs thread-per-call dispatch (ips)")
        lines << "    x-axis [#{scenario_names.join(", ")}]"
        lines << %(    y-axis "ips")
        lines << %(    bar "native" [#{chartable.map { |s| s[:native_ips].round(1) }.join(", ")}])
        lines << %(    bar "thread-per-call" [#{chartable.map { |s| s[:ips].round(1) }.join(", ")}])
        lines << "```"
        lines << ""
      end
      lines.join("\n")
    end

    def self.build_throughput_chart(latest)
      return "" if latest.empty?

      envs = sorted_environments(latest.keys)
      # camping_trip_email is ~5 orders of magnitude slower than the other
      # scenarios (it's an entity-count allocation stress test, not a
      # comparable per-call latency case) -- including it here would make
      # every other bar visually disappear. Its exact numbers are still in
      # the results table above.
      chartable_scenarios = latest.values.first[:scenarios].reject { |s| CHART_EXCLUDED_SCENARIOS.include?(s[:name]) }
      return "" if chartable_scenarios.empty?

      scenario_names = chartable_scenarios.map { |s| s[:name] }
      lines = ["```mermaid", "xychart-beta", %(    title "Duckling.parse throughput (ips) -- latest run per environment")]
      lines << "    x-axis [#{scenario_names.join(", ")}]"
      lines << %(    y-axis "ips")
      envs.each do |env|
        values = latest.fetch(env)[:scenarios]
          .reject { |s| CHART_EXCLUDED_SCENARIOS.include?(s[:name]) }
          .map { |s| s[:ips].round(1) }
        lines << %(    bar "#{env}" [#{values.join(", ")}])
      end
      lines << "```"
      lines.join("\n")
    end

    def self.build_concurrency_chart(latest)
      return "" if latest.empty?

      envs = sorted_environments(latest.keys)
      values = envs.map { |env| latest.fetch(env)[:concurrency][:efficiency_pct].round(1) }
      lines = ["```mermaid", "xychart-beta", %(    title "10-thread concurrency scaling efficiency (%) -- latest run per environment")]
      lines << "    x-axis [#{envs.join(", ")}]"
      lines << %(    y-axis "efficiency %")
      lines << %(    bar "efficiency_pct" [#{values.join(", ")}])
      lines << "```"
      lines.join("\n")
    end

    def self.render_docs_readme(history)
      latest = latest_per_environment(history)
      <<~MARKDOWN
        # Benchmark history

        Results of the `benchmark-ips` suite in [`../../benchmark/parse_benchmark.rb`](../../benchmark/parse_benchmark.rb),
        run against `Duckling.parse` (wall-clock ips, GC/allocation pressure, and
        10-thread concurrency scaling). This file is fully auto-generated by
        `bundle exec rake benchmark:record` — do not hand-edit it, changes will be
        overwritten on the next run.

        Results are split **by environment** rather than blended into a single
        release-over-release trend. GitHub Actions runners, Claude Code Web
        sessions, and local dev machines have too much hardware/scheduling
        variance to compare directly — a 20-30% swing between two runs on
        different machines is normal and not a regression. Comparing an
        environment against *itself* over time, or against other environments
        side by side (as below), is more meaningful than a single blended number.

        Raw JSON lives under `<environment>/<version>.json` in this directory —
        one file per environment per recorded version.

        ## Latest results by environment

        #{build_results_table(latest)}
        #{build_throughput_chart(latest)}

        #{build_concurrency_chart(latest)}
      MARKDOWN
    end

    def self.write_docs_readme!(content, path: DEFAULT_DOCS_README_PATH)
      File.write(path, content)
    end

    def self.run(environment: ENVIRONMENT, version: Duckling::VERSION)
      payload = write_json(environment: environment, version: version, results: DucklingBenchmark.run)
      write_docs_readme!(render_docs_readme(history))
      payload
    end
  end
end

if __FILE__ == $0
  DucklingBenchmark::Report.run
end
