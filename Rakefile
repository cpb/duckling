# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rake/extensiontask"

Rake::ExtensionTask.new("duckling") do |ext|
  ext.lib_dir = "lib/duckling"
end

task :dev do
  ENV["RB_SYS_CARGO_PROFILE"] = "dev"
end

Minitest::TestTask.create

require "standard/rake"

task default: %i[standard compile test]

# bundler/gem_tasks's default `release` task builds and pushes the .gem
# itself, which would race the tag-triggered CI pipeline in
# .github/workflows/release.yml that already does the actual build and
# publish once a vX.Y.Z tag lands. Narrow `release` to just tagging.
Rake::Task["release"].clear
task release: ["release:guard_clean", "release:source_control_push"]
