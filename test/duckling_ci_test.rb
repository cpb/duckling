# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../cross_targets"

class DucklingCiTest < Minitest::Test
  CROSS_GEM_WORKFLOW = File.expand_path("../.github/workflows/cross-gem.yml", __dir__)

  def test_native_extension_infrastructure
    ext_dir = File.join(__dir__, "../ext/duckling")

    assert File.exist?(File.join(ext_dir, "Cargo.toml")),
      "ext/duckling/Cargo.toml must exist — Rust crate not yet set up"

    cargo = File.read(File.join(ext_dir, "Cargo.toml"))
    assert_match(/\[lib\]/, cargo, "Cargo.toml must declare a [lib] section")
    assert_match(/crate-type.*cdylib/, cargo, "Cargo.toml must set crate-type = [\"cdylib\"]")
  end

  # cross_targets.rb states which platforms and Ruby ABIs the gems are built
  # for, and everything that can read Ruby reads it there. cross-gem.yml cannot
  # — YAML has no way to require a file — so it restates the same matrix, and
  # these tests are the only thing holding the copy to the original.
  #
  # A Ruby ABI needs a binary built for it and a smoke test that loads it on a
  # real Ruby of that version. Drop an ABI from the smoke matrix and the gem
  # still builds, still verifies, and still publishes, with nothing having
  # loaded that binary — and an ABI mismatch is invisible to every check that
  # only reads a gem file.
  def test_every_cross_compiled_ruby_abi_is_built_and_smoke_tested
    abis = normalize(CrossTargets::RUBY_ABIS)

    assert_equal abis, normalize(cross_gem_step.fetch("with").fetch("ruby-versions").split(",")),
      "`ruby-versions` builds a different ABI set than CrossTargets::RUBY_ABIS"

    assert_equal abis, normalize(job("smoke").fetch("strategy").fetch("matrix").fetch("ruby")),
      "the smoke job runs a different ABI set than CrossTargets::RUBY_ABIS — " \
      "an ABI missing here ships in every gem without ever being loaded"
  end

  # Adding a platform takes three edits: cross_targets.rb, cross-gem.yml's build
  # matrix, and cross-gem.yml's smoke matrix. The build matrix alone is the edit
  # that looks sufficient.
  def test_every_cross_compiled_platform_is_built_and_smoke_tested
    platforms = CrossTargets::PLATFORMS.keys.sort

    assert_equal platforms, job("cross_gems").fetch("strategy").fetch("matrix").fetch("platform").sort,
      "the cross-compile job builds different platforms than CrossTargets::PLATFORMS"

    assert_equal platforms, job("smoke").fetch("strategy").fetch("matrix").fetch("platform").sort,
      "the smoke job covers different platforms than CrossTargets::PLATFORMS — " \
      "a platform missing here ships without ever running on its own hardware"
  end

  # GitHub leaves a job asking for a runner label that does not exist queued
  # rather than failing it, so the run never reports at all. The label has to
  # come from somewhere a human reviews, which is cross_targets.rb.
  def test_every_smoke_tested_platform_runs_on_its_declared_runner
    expected = CrossTargets::PLATFORMS.transform_values { |target| target.fetch(:runner) }

    assert_equal expected, include_map("smoke", "runner"),
      "the smoke job's runner labels disagree with CrossTargets::PLATFORMS"
  end

  private

  def workflow
    @workflow ||= YAML.load_file(CROSS_GEM_WORKFLOW)
  end

  def job(name)
    workflow.fetch("jobs").fetch(name)
  end

  def cross_gem_step
    step = job("cross_gems").fetch("steps").find { |s| s["id"] == "cross-gem" }
    refute_nil step, "cross-gem.yml needs the cross-compile step to keep `id: cross-gem`"
    step
  end

  # A matrix `include:` entry pairs a platform with one extra field.
  def include_map(job_name, field)
    job(job_name).fetch("strategy").fetch("matrix").fetch("include")
      .select { |entry| entry.key?(field) }
      .to_h { |entry| [entry.fetch("platform"), entry.fetch(field)] }
  end

  # YAML turns an unquoted 4.0 into a Float, and the order of the ABIs is a
  # matter of taste in each file. Neither is a drift worth failing over.
  def normalize(abis)
    abis.map(&:to_s).sort_by { |abi| Gem::Version.new(abi) }
  end
end
