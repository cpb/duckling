# frozen_string_literal: true

require "bundler/gem_tasks"
require "dotenv"
require "minitest/test_task"
require "rb_sys/extensiontask"

require_relative "cross_targets"

# Loads RB_SYS_CARGO_PROFILE=dev from .env.local when present (seeded by
# bin/setup from .env.local.example), so local compiles default to the dev
# profile without needing the :dev task below. .env.local is gitignored and
# never checked out in CI, so `bundle exec rake` there still builds release.
Dotenv.load(".env.local")

GEMSPEC = Gem::Specification.load("duckling.gemspec")

RbSys::ExtensionTask.new("duckling", GEMSPEC) do |ext|
  ext.lib_dir = "lib/duckling"

  # rake-compiler derives a native gem's required_ruby_version from the ABIs
  # it cross-compiled against, and writes its own floor over the gemspec's.
  # The gemspec's floor can be stricter, so state both bounds here: the
  # gemspec's own requirement, plus the ceiling from cross_targets.rb.
  ext.cross_compiling do |spec|
    spec.required_ruby_version =
      GEMSPEC.required_ruby_version.as_list + ["< #{CrossTargets::ABI_CEILING}"]
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
# So this fix changes ENV here, in the Rakefile.
# The fix adds a prerequisite task to the local build's Makefile task.
# This prerequisite task sets the correct host target. It runs before
# the Makefile task, and before `make` runs later.
if (ruby_target = ENV["RUBY_TARGET"]) && ruby_target != RUBY_PLATFORM
  local_makefile = "tmp/#{RUBY_PLATFORM}/duckling/#{RUBY_VERSION}/Makefile"

  # CARGO_BUILD_TARGET must hold a real triple before RUST_TARGET goes
  # away. Clearing RUST_TARGET alone lets rb_sys fall back to the target
  # baked into the container's $CARGO_HOME/config.toml, which is the
  # cross-compile target again. So a host triple that cannot be read is a
  # hard error.
  #
  # Both variables belong to the whole rake process, and the cross build
  # reads them too. This is safe only because rake generates the cross
  # Makefile, which bakes its own --target in, before packaging reaches
  # the local pass. Nothing in rake states that order. If it ever
  # inverted, the cross build would compile for the host and produce a
  # correctly *named* binary for the wrong architecture — which is what
  # `file(1)` on every binary in test/gem/packaged_gem_test.rb catches.
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

# rb-sys-dock mounts the working directory into the build container with
# `-v $(pwd):$(pwd)` and nothing else. In a git worktree — which is how
# bin/worktree sets up every branch here — .git is a *file* naming a path under
# the main checkout's .git/worktrees/, which that mount does not cover. Every
# git command inside the container then fails, including the `git ls-files` in
# duckling.gemspec, whose file list comes back empty. The gem that comes out
# holds the compiled binaries and no Ruby at all.
#
# So build from a throwaway plain clone instead, whose .git is a real
# directory under the mount. Two consequences: the gem carries *committed*
# state (uncommitted changes are excluded), and the clone gets its own Cargo
# target directory separate from this checkout's.
CLONE_DIR = "tmp/native_gem_clone"

def build_native_gem(platform)
  # bundler exports BUNDLE_GEMFILE pointing at this checkout, and rb-sys-dock
  # mounts $(pwd) — the two have to move together or the container gets one
  # directory's Gemfile and another's source.
  Bundler.with_unbundled_env do
    sh "bundle", "install"
    sh "bundle", "exec", "rb-sys-dock", "--platform", platform,
      "--ruby-versions", CrossTargets::RUBY_ABIS.join(","), "--build"
  end
end

desc "Cross-compile the native extension for a given platform via rb-sys-dock (e.g. `rake 'native_gem[x86_64-linux]'`)"
task :native_gem, [:platform] do |_t, platform:|
  next build_native_gem(platform) unless File.file?(".git")

  head = `git rev-parse HEAD`.strip
  raise "Could not read HEAD to pin the build clone." if head.empty?

  unless `git status --porcelain`.empty?
    warn "native_gem: building #{head[0, 7]} from a clone — uncommitted changes are not in this gem."
  end

  rm_rf CLONE_DIR
  begin
    sh "git", "clone", "--local", "--no-checkout", Dir.pwd, CLONE_DIR
    sh "git", "-C", CLONE_DIR, "checkout", "--detach", head

    Dir.chdir(CLONE_DIR) { build_native_gem(platform) }

    mkdir_p "pkg"
    cp FileList["#{CLONE_DIR}/pkg/*.gem"], "pkg"
  ensure
    rm_rf CLONE_DIR
  end
end

# The EN corpora vendored into test/fixtures/wafer_corpus.json come from this
# repository. See docs/wafer-corpus.md.
UPSTREAM_CORPUS_REPO = "https://github.com/wafer-inc/duckling"
CORPUS_CLONE_DIR = "tmp/wafer-duckling"

namespace :corpus do
  desc "Re-extract test/fixtures/wafer_corpus.json from wafer-inc/duckling (e.g. `rake 'corpus:refresh[c96b068]'`)"
  task :refresh, [:ref] do |_task, ref: nil|
    rm_rf CORPUS_CLONE_DIR
    mkdir_p File.dirname(CORPUS_CLONE_DIR)

    # A blobless clone keeps the whole history reachable, so any ref can be
    # checked out, without fetching every blob in it.
    sh "git", "clone", "--filter=blob:none", UPSTREAM_CORPUS_REPO, CORPUS_CLONE_DIR
    sh "git", "-C", CORPUS_CLONE_DIR, "checkout", "--detach", ref if ref

    ruby "script/extract_wafer_corpus.rb", "--upstream", CORPUS_CLONE_DIR
  end
end

task :benchmark_env do
  # Force a realistic release-profile build regardless of .env.local's
  # RB_SYS_CARGO_PROFILE=dev (local dev checkouts only; CI never has it).
  # Must reenable :compile in case it already ran earlier in this same
  # rake process, so it recompiles under the forced profile. A stale
  # dev-profile build would be reused otherwise.
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
    # Explicit bash: Rake's default `sh -c` is dash on Debian/Ubuntu
    # runners, and dash's `set` doesn't support the `-o pipefail` flag below.
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

# The default suite exercises the extension compiled in this checkout.
# Three test subtrees run outside it:
# - test/gem/ exercises a *built* or *installed* gem instead — it needs one
#   handed to it, and the installed suite must not see this checkout's lib/.
# - test/capabilities/ is loaded by test_helper itself, gated on the tz probes.
# - test/environments/ holds contracts invoked directly by their CI step.
# See docs/tz-database-axis.md.
Minitest::TestTask.create do |t|
  t.test_globs = FileList["test/**/*_test.rb"].exclude("test/gem/**/*", "test/capabilities/**/*", "test/environments/**/*")
end

# Minitest::TestTask has no built-in way to declare a task dependency, and
# `task default: %i[standard compile test]`'s array ordering only protects
# `bundle exec rake` itself — `bundle exec rake test` run directly has no
# guarantee `compile` ran first, which would surface as a confusing
# LoadError/stale-behavior failure unrelated to the code under test.
task test: %i[compile]

require "standard/rake"

task default: %i[standard compile test]

# bundler/gem_tasks's default `release` task builds and pushes the .gem
# itself, which would race the tag-triggered CI pipeline in
# .github/workflows/release.yml that already does the actual build and
# publish once a vX.Y.Z tag lands. Narrow `release` to just tagging.
Rake::Task["release"].clear
task release: ["release:guard_clean", "release:source_control_push"]
