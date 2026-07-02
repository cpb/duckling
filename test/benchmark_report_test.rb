# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../benchmark/report"

# These tests exercise DucklingBenchmark::Report's pure file/string-generation
# logic using fixture data shaped like the JSON schema. They deliberately
# never call DucklingBenchmark.run/run_ips/throughput (the real benchmark-ips
# suite + GC sampling + thread pool takes tens of seconds) and never invoke
# benchmark:record_pr or any git/gh command -- keep it that way so `rake test`
# stays fast and deterministic. If you want to exercise the real suite, run
# `bin/benchmark` by hand.
class DucklingBenchmarkReportTest < Minitest::Test
  def fixture_results(ips_base: 100.0)
    {
      ruby_version: RUBY_VERSION,
      ruby_platform: RUBY_PLATFORM,
      rust_toolchain: "rustc 1.94.1",
      cargo_profile: "release",
      scenarios: DucklingBenchmark::CORPUS.each_with_index.map do |s, i|
        {
          name: s[:name], input: s[:input],
          ips: ips_base + i, ips_stddev_pct: 1.0, iterations: 1000, microseconds_per_call: 10.0,
          allocated_objects_per_call: 5.0, minor_gc_count_delta: 1, major_gc_count_delta: 0
        }
      end,
      concurrency: {
        thread_count: 10, duration_seconds: 3, scenario_input: "medium",
        single_thread_ops_per_sec: 100.0, multi_thread_ops_per_sec: 260.0,
        scaling_factor: 2.6, efficiency_pct: 26.0
      }
    }
  end

  def fixture_entry(environment:, version:, ips_base: 100.0)
    fixture_results(ips_base: ips_base).merge(environment: environment, version: version, date: "2026-01-01")
  end

  def test_detect_environment_prefers_github_actions
    env = DucklingBenchmark::Report.detect_environment({"GITHUB_ACTIONS" => "true", "CLAUDE_CODE_REMOTE" => "true"})
    assert_equal "github-actions", env
  end

  def test_detect_environment_claude_code_web
    env = DucklingBenchmark::Report.detect_environment({"CLAUDE_CODE_REMOTE" => "true"})
    assert_equal "claude-code-web", env
  end

  def test_detect_environment_defaults_to_local
    assert_equal "local", DucklingBenchmark::Report.detect_environment({})
  end

  def test_write_json_and_history_round_trip
    Dir.mktmpdir do |dir|
      DucklingBenchmark::Report.write_json(environment: "github-actions", version: "0.2.1", results: fixture_results, dir: dir)
      DucklingBenchmark::Report.write_json(environment: "local", version: "0.2.1", results: fixture_results, dir: dir)

      history = DucklingBenchmark::Report.history(dir: dir)
      assert_equal 2, history.size
      assert_equal ["github-actions", "local"], history.map { |e| e[:environment] }.sort
      assert history.all? { |e| e[:version] == "0.2.1" }
    end
  end

  def test_latest_per_environment_picks_max_version
    history = [
      fixture_entry(environment: "local", version: "0.2.0"),
      fixture_entry(environment: "local", version: "0.2.1"),
      fixture_entry(environment: "github-actions", version: "0.2.0")
    ]
    latest = DucklingBenchmark::Report.latest_per_environment(history)
    assert_equal "0.2.1", latest.fetch("local")[:version]
    assert_equal "0.2.0", latest.fetch("github-actions")[:version]
  end

  def test_render_docs_readme_with_no_data
    content = DucklingBenchmark::Report.render_docs_readme([])
    assert_includes content, "No benchmark data recorded yet"
  end

  def test_render_docs_readme_with_data
    history = [
      fixture_entry(environment: "github-actions", version: "0.2.1", ips_base: 100.0),
      fixture_entry(environment: "local", version: "0.2.1", ips_base: 500.0)
    ]
    content = DucklingBenchmark::Report.render_docs_readme(history)

    assert_includes content, "github-actions"
    assert_includes content, "local"
    DucklingBenchmark::CORPUS.each { |s| assert_includes content, s[:name] }
    assert_includes content, "xychart-beta"
    assert_includes content, "```mermaid"
  end

  def test_write_docs_readme_writes_content
    Dir.mktmpdir do |dir|
      path = File.join(dir, "README.md")
      DucklingBenchmark::Report.write_docs_readme!("hello world", path: path)
      assert_equal "hello world", File.read(path)
    end
  end
end
