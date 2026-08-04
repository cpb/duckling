# frozen_string_literal: true

require "bundler/gem_tasks"
require "dotenv"
require "minitest/test_task"
require "rb_sys/extensiontask"

# Loads RB_SYS_CARGO_PROFILE=dev from .env.local when present (seeded by
# bin/setup from .env.local.example), so local compiles default to the dev
# profile without needing the :dev task below. .env.local is gitignored and
# never checked out in CI, so `bundle exec rake` there still builds release.
Dotenv.load(".env.local")

GEMSPEC = Gem::Specification.load("duckling.gemspec")

RbSys::ExtensionTask.new("duckling", GEMSPEC) do |ext|
  ext.lib_dir = "lib/duckling"
end

# Rake::ExtensionTask *always* also compiles one unconditional "local"
# (non-cross) pass using the container's own host Ruby -- BaseExtensionTask's
# ungated define_compile_tasks(nil, ...) call, keyed to RUBY_PLATFORM, not
# gated by cross_compile at all -- and Gem::PackageTask (RubyGems stdlib)
# always lists the compiled artifact's bare gem-relative path as a literal
# prerequisite of the final packaged .gem. Every rbsys/<platform> Docker
# image bakes RUST_TARGET/CARGO_BUILD_TARGET into its environment so a bare
# `cargo build` targets that image's platform by default -- inherited by
# every subprocess in the container, including this unwanted local pass. On
# x86_64-linux/x86_64-darwin/arm64-darwin that's harmless (either it's the
# real target, or it produces a differently-named duckling.bundle nothing
# depends on), but on aarch64-linux this local pass ends up compiling for
# aarch64 while linking with the plain host gcc rake-compiler picked for
# "x86_64-linux" -- a mismatch that fails to link, and since duckling.so is
# the same filename the real aarch64-linux task also needs, packaging pulls
# in the broken result. Env vars set inside extconf.rb's own subprocess
# don't propagate back to this parent process (which is what actually runs
# `make`), so the fix has to mutate ENV here, as a prerequisite of the local
# pass's own Makefile task, restoring a genuine host target before its
# Makefile gets generated and before `make` (run later, same process) reads
# whatever's left in ENV.
if (ruby_target = ENV["RUBY_TARGET"]) && ruby_target != RUBY_PLATFORM
  local_makefile = "tmp/#{RUBY_PLATFORM}/duckling/#{RUBY_VERSION}/Makefile"

  task :fix_local_pass_cargo_target do
    host_target = `rustc -vV`[/^host: (\S+)$/, 1]
    ENV["CARGO_BUILD_TARGET"] = host_target if host_target
    ENV.delete("RUST_TARGET")
  end

  Rake::Task[local_makefile].enhance([:fix_local_pass_cargo_target]) if Rake::Task.task_defined?(local_makefile)
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
