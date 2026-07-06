# frozen_string_literal: true

require "bundler/gem_tasks"
require "dotenv"
require "minitest/test_task"
require "rb_sys/extensiontask"
require "wiki_promoter/tasks" # wiki:migrate / wiki:publish -- see AGENTS.md's Gemfile entry

# Loads RB_SYS_CARGO_PROFILE=dev from .env.local when present (seeded by
# bin/setup from .env.local.example), so local compiles default to the dev
# profile without needing the :dev task below. .env.local is gitignored and
# never checked out in CI, so `bundle exec rake` there still builds release.
Dotenv.load(".env.local")

GEMSPEC = Gem::Specification.load("duckling.gemspec")

RbSys::ExtensionTask.new("duckling", GEMSPEC) do |ext|
  ext.lib_dir = "lib/duckling"
  ext.cross_compile = true
  ext.cross_platform = ["x86_64-linux", "x86_64-darwin"]
end

task :dev do
  ENV["RB_SYS_CARGO_PROFILE"] = "dev"
end

desc "Cross-compile the native extension for a given platform via rb-sys-dock (e.g. `rake 'native_gem[x86_64-linux]'`)"
task :native_gem, [:platform] do |_t, platform:|
  sh "bundle", "exec", "rb-sys-dock", "--platform", platform, "--ruby-versions", "3.2", "--build"
end

task :benchmark_env do
  # Force a realistic release-profile build regardless of .env.local's
  # RB_SYS_CARGO_PROFILE=dev (local dev checkouts only, never present in
  # CI). Must reenable :compile in case it already ran earlier in this same
  # rake process, so it's guaranteed to recompile under the forced profile
  # rather than reusing a stale dev-profile build.
  ENV.delete("RB_SYS_CARGO_PROFILE")
  Rake::Task[:compile].reenable
end

desc "Run the benchmark-ips suite (console output only, no file writes)"
task benchmark: [:benchmark_env, :compile] do
  ruby "-Ilib", "benchmark/parse_benchmark.rb"
end

namespace :benchmark do
  desc "Run benchmarks, write docs/benchmarks/<environment>/<version>.json, regenerate docs/benchmarks/README.md"
  task record: [:benchmark_env, :compile] do
    ruby "-Ilib", "benchmark/report.rb"
  end

  desc "Run :record on a fresh branch off origin/main, then commit/push and open+auto-merge a PR via gh"
  task record_pr: ["release:guard_clean"] do
    # Explicit bash, not Rake's default `sh -c` (dash on Debian/Ubuntu
    # runners): dash's `set` doesn't support the `-o pipefail` flag below.
    sh("bash", "-c", <<~SH)
      set -euo pipefail
      original_ref="$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)"
      git fetch origin main
      git checkout -b "benchmark/pending-$(date +%s)" origin/main

      bundle exec rake benchmark:record

      version="$(ruby -Ilib -e 'require "duckling"; puts Duckling::VERSION')"
      environment="$(ruby -Ilib -e 'require_relative "benchmark/report"; puts DucklingBenchmark::Report::ENVIRONMENT')"
      branch="benchmark/${environment}/${version}-$(date +%s)"
      git branch -m "$branch"

      git add docs/benchmarks
      git commit -m "Record ${environment} benchmark results for ${version}"
      git push origin "$branch"
      gh pr create --base main --head "$branch" \\
        --title "Benchmark results (${environment}, ${version})" \\
        --body "Automated benchmark recording from ${environment}."
      gh pr merge "$branch" --auto --squash

      git checkout "$original_ref"
      git branch -D "$branch"
    SH
  end
end

Minitest::TestTask.create

# Minitest::TestTask has no built-in way to declare a task dependency, and
# `task default: %i[standard compile test]`'s array ordering only protects
# `bundle exec rake` itself — `bundle exec rake test` run directly has no
# guarantee `compile` ran first, which would surface as a confusing
# LoadError/stale-behavior failure unrelated to the code under test.
task test: :compile

require "standard/rake"

task default: %i[standard compile test]

# bundler/gem_tasks's default `release` task builds and pushes the .gem
# itself, which would race the tag-triggered CI pipeline in
# .github/workflows/release.yml that already does the actual build and
# publish once a vX.Y.Z tag lands. Narrow `release` to just tagging.
Rake::Task["release"].clear
task release: ["release:guard_clean", "release:source_control_push"]
