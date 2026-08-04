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

  # rake-compiler derives a native gem's required_ruby_version from the
  # Ruby versions it cross-compiled against. One version (3.2) gives
  # ">= 3.2, < 3.3.dev", which makes RubyGems refuse the precompiled gem
  # on every later Ruby and quietly fall back to the source gem — the
  # exact outcome precompiled gems exist to prevent.
  #
  # rb-sys's stable-api-compiled-fallback feature targets Ruby's
  # ABI-stable C API, so one binary built against the 3.2 floor runs on
  # every Ruby the gemspec allows. Restore the gemspec's own constraint.
  ext.cross_compiling do |spec|
    spec.required_ruby_version = GEMSPEC.required_ruby_version
  end
end

# rake-compiler always builds two things for this extension:
# - The real cross build for RUBY_TARGET.
# - An extra "local" build for the host Ruby. rake-compiler runs this
#   local build even when cross_compile is off.
#
# Gem::PackageTask lists the local build's plain output path as a
# prerequisite of the final .gem file.
#
# Each rbsys/<platform> Docker image sets RUST_TARGET and
# CARGO_BUILD_TARGET in its environment. These variables make a plain
# `cargo build` target that image's platform. Every process in the
# container inherits them, including the local build.
#
# On x86_64-linux, x86_64-darwin, and arm64-darwin, this causes no
# problem:
# - The local build's target is already correct, or
# - The local build makes a file (duckling.bundle) that nothing else
#   needs.
#
# On aarch64-linux, the local build compiles code for aarch64, but
# links the code with the host's plain gcc. rake-compiler picked this
# gcc for a different platform. The link step then fails.
#
# The local build's output file is named duckling.so. The real
# aarch64-linux build needs a file with the same name. So the
# packaging step uses the broken file from the local build.
#
# extconf.rb runs in its own subprocess. ENV changes made there do not
# reach the parent process, and the parent process runs `make`.
#
# So this fix changes ENV here, in the Rakefile, not in extconf.rb.
# The fix adds a prerequisite task to the local build's Makefile task.
# This prerequisite task sets the correct host target. It runs before
# the Makefile task, and before `make` runs later.
if (ruby_target = ENV["RUBY_TARGET"]) && ruby_target != RUBY_PLATFORM
  local_makefile = "tmp/#{RUBY_PLATFORM}/duckling/#{RUBY_VERSION}/Makefile"

  task :fix_local_pass_cargo_target do
    host_target = `rustc -vV`[/^host: (\S+)$/, 1]
    ENV["CARGO_BUILD_TARGET"] = host_target if host_target
    ENV.delete("RUST_TARGET")
  end

  # local_makefile reconstructs a path rake-compiler builds from its own
  # internals (tmp_dir, extension name, the local pass's Ruby version).
  # A gem upgrade can change any of them. Say so here, because the
  # alternative is a silent no-op and a link failure deep in a container.
  unless Rake::Task.task_defined?(local_makefile)
    raise "Expected rake-compiler to define a Makefile task at #{local_makefile}. " \
      "The local-pass Cargo target override needs that exact task name — check " \
      "define_compile_tasks in rake-compiler's extensiontask.rb for the current path."
  end

  Rake::Task[local_makefile].enhance([:fix_local_pass_cargo_target])
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
