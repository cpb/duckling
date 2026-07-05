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

WIKI_ROADMAP_PATH = "docs/2026-07-01-roadmap.md"

namespace :wiki do
  desc "Flatten+relink a docs/<issue>-slug/ tree into tmp/wiki-migration/ for inspection (no network, no credentials)"
  task :migrate, [:docs_path] do |_t, args|
    require_relative "wiki/migrator"

    migrator = WikiMigration::Migrator.new(args.fetch(:docs_path))
    out_dir = "tmp/wiki-migration"
    rm_rf out_dir
    mkdir_p out_dir
    pages = migrator.pages
    pages.each { |name, content| File.write(File.join(out_dir, name), content) }

    puts "Wrote #{pages.size} page(s) to #{out_dir}/ (entry page: #{migrator.entry_page_name}):"
    pages.each_key { |name| puts "  #{name}" }
  end

  desc "Push wiki:migrate's output to the real wiki, then remove the source docs/ tree from this branch and repoint the roadmap link at it"
  task :publish, [:docs_path] => ["release:guard_clean"] do |_t, args|
    docs_path = args.fetch(:docs_path)
    sh "bundle", "exec", "rake", "wiki:migrate[#{docs_path}]"

    require_relative "wiki/migrator"
    entry_url = "https://github.com/cpb/duckling/wiki/#{WikiMigration::Migrator.new(docs_path).entry_page_name}"
    token = ENV.fetch("WIKI_DEPLOY_TOKEN") { abort "WIKI_DEPLOY_TOKEN is required to push to the wiki (the default GITHUB_TOKEN can't write to a repo's wiki)" }
    wiki_checkout = "tmp/wiki-checkout"

    # Explicit bash, not Rake's default `sh -c` (dash on Debian/Ubuntu
    # runners): dash's `set` doesn't support the `-o pipefail` flag below.
    sh("bash", "-c", <<~SH)
      set -euo pipefail

      if [ -d "#{wiki_checkout}/.git" ]; then
        git -C "#{wiki_checkout}" fetch origin
        git -C "#{wiki_checkout}" reset --hard origin/master
      else
        git clone "https://x-access-token:#{token}@github.com/cpb/duckling.wiki.git" "#{wiki_checkout}"
      fi

      for f in tmp/wiki-migration/*.md; do
        name="$(basename "$f")"
        target="#{wiki_checkout}/$name"
        if [ -f "$target" ] && ! diff -q "$f" "$target" >/dev/null; then
          echo "Refusing to overwrite existing wiki page with different content: $name" >&2
          echo "Pass WIKI_FORCE=1 to overwrite anyway." >&2
          [ "${WIKI_FORCE:-}" = "1" ] || exit 1
        fi
        cp "$f" "$target"
      done

      cd "#{wiki_checkout}"
      git add .
      if git diff --cached --quiet; then
        echo "No wiki changes to push."
      else
        git commit -m "Migrate #{docs_path} research to the wiki"
        git push origin HEAD:master
      fi
    SH

    puts "Pushed to https://github.com/cpb/duckling/wiki:"
    Dir.glob("tmp/wiki-migration/*.md").sort.each { |f| puts "  https://github.com/cpb/duckling/wiki/#{File.basename(f, ".md")}" }

    if Dir.exist?(docs_path)
      if File.exist?(WIKI_ROADMAP_PATH)
        original = File.read(WIKI_ROADMAP_PATH)
        updated = WikiMigration.repoint_references(original, docs_path: docs_path, entry_url: entry_url)
        File.write(WIKI_ROADMAP_PATH, updated) if updated != original
      end

      sh "git", "rm", "-r", "--quiet", docs_path
      sh "git", "add", WIKI_ROADMAP_PATH if File.exist?(WIKI_ROADMAP_PATH)
      sh "git", "commit", "-m", "Migrate #{docs_path} research to the wiki; drop local tree"

      # actions/checkout leaves a detached HEAD, where a bare `git push
      # origin HEAD` has no implied destination ref -- GITHUB_REF_NAME (set
      # by the Actions runtime) covers that case; a plain local checkout
      # falls back to the actually-attached branch.
      branch = ENV["GITHUB_REF_NAME"] || `git symbolic-ref -q --short HEAD`.strip
      abort "Could not determine a branch to push to (detached HEAD, no GITHUB_REF_NAME)" if branch.empty?
      sh "git", "push", "origin", "HEAD:refs/heads/#{branch}"
    else
      puts "#{docs_path} already removed from this branch; skipping the cleanup commit."
    end
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
