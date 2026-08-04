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

# Ruby ABIs each precompiled gem carries a binary for.
#
# rb-sys reads Ruby's internal object layout through the headers it compiles
# against. A binary understands only the Ruby that built it. See the loader in
# lib/duckling.rb.
#
# This list must agree with three fields in .github/workflows/cross-gem.yml,
# which builds the gems that ship: `ruby-versions`, `EXPECTED_ABIS`, and the
# smoke job's `ruby` matrix.
#
# The rbsys/<platform> images carry the toolchains for these ABIs. Check
# /usr/local/rake-compiler/config.yml in the image before adding one.
CROSS_RUBY_ABIS = %w[3.2 3.3 3.4 4.0].freeze

# The first Ruby the precompiled gems do not carry a binary for.
#
# RubyGems must skip a precompiled gem on such a Ruby and take the source gem,
# which compiles a matching binary at install time. Without this cap RubyGems
# installs a gem with no usable binary, and the gem raises LoadError on
# require.
CROSS_RUBY_ABI_CEILING = begin
  major, minor = CROSS_RUBY_ABIS.max_by { |abi| Gem::Version.new(abi) }.split(".").map(&:to_i)
  "#{major}.#{minor + 1}.dev"
end

RbSys::ExtensionTask.new("duckling", GEMSPEC) do |ext|
  ext.lib_dir = "lib/duckling"

  # rake-compiler derives a native gem's required_ruby_version from the ABIs
  # it cross-compiled against, and writes its own floor over the gemspec's.
  # The gemspec's floor can be stricter, so state both bounds here: the
  # gemspec's own requirement, plus the ceiling above.
  ext.cross_compiling do |spec|
    spec.required_ruby_version =
      GEMSPEC.required_ruby_version.as_list + ["< #{CROSS_RUBY_ABI_CEILING}"]
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
# The Ruby that drives rake in each container is an x86_64 Linux Ruby.
# So the local build always makes a file named duckling.so.
#
# On x86_64-linux, this causes no problem. The local build's target is
# already correct.
#
# On x86_64-darwin and arm64-darwin, this causes no problem either.
# Those gems need duckling.bundle. They do not list duckling.so, so the
# local build is not a prerequisite and never runs.
#
# On aarch64-linux, the two names collide. The gem needs duckling.so,
# which is the name the local build makes. So the packaging step waits
# for the local build. That build compiles code for aarch64, but links
# the code with the host's plain gcc. rake-compiler picked this gcc for
# the host platform. The link step then fails, and stops the build.
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

  # CARGO_BUILD_TARGET must hold a real triple before RUST_TARGET goes
  # away. Clearing RUST_TARGET alone lets rb_sys fall back to the target
  # baked into the container's $CARGO_HOME/config.toml, which is the
  # cross-compile target again. So a host triple that cannot be read is a
  # hard error, not something to skip past.
  task :fix_local_pass_cargo_target do
    rustc_version_info = begin
      `rustc -vV`
    rescue Errno::ENOENT
      raise "Cannot run `rustc -vV` to find the host target triple. rustc must be on PATH."
    end

    host_target = rustc_version_info[/^host: (\S+)$/, 1]
    raise "`rustc -vV` printed no `host:` line:\n#{rustc_version_info}" unless host_target

    ENV["CARGO_BUILD_TARGET"] = host_target
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
  sh "bundle", "exec", "rb-sys-dock", "--platform", platform,
    "--ruby-versions", CROSS_RUBY_ABIS.join(","), "--build"
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
