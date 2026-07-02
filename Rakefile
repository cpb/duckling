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
