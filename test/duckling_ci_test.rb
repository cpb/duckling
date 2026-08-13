# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../cross_targets"

class DucklingCiTest < Minitest::Test
  CROSS_GEM_WORKFLOW = File.expand_path("../.github/workflows/cross-gem.yml", __dir__)
  RELEASE_WORKFLOW = File.expand_path("../.github/workflows/release.yml", __dir__)

  def test_native_extension_infrastructure
    ext_dir = File.join(__dir__, "../ext/duckling")

    assert File.exist?(File.join(ext_dir, "Cargo.toml")),
      "ext/duckling/Cargo.toml must exist — Rust crate not yet set up"

    # Explicit UTF-8 rather than Encoding.default_external: these files carry
    # prose comments with em-dashes, and on a host whose locale leaves the
    # default at US-ASCII (a bare container, a cron shell) every match against
    # the contents raises "invalid byte sequence" instead of reporting on the
    # config it was asked about.
    cargo = File.read(File.join(ext_dir, "Cargo.toml"), encoding: "UTF-8")
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

  # The GitHub Packages half of #107 lives only in release.yml — there is no
  # cross_targets.rb-style original for a test to hold it honest against.
  # What a test can pin is the wiring whose loss would otherwise surface only
  # as an auth failure during a real release: the push step itself, the
  # `packages: write` permission its GITHUB_TOKEN authentication needs (the
  # publish job's permissions block replaces the workflow-level one, so a
  # refactor that drops the key drops the authentication), and the
  # `unset GEM_HOST_API_KEY` that stops the RubyGems token — exported
  # job-wide by configure-rubygems-credentials — from shadowing the push's
  # --key flag (gem push checks that env var first; v0.4.4's publish 401ed
  # without it). AGENTS.md's "Publish credentials" section describes the
  # RubyGems-side equivalent of this failure shape as uncatchable; this side
  # is catchable.
  def test_release_publishes_to_github_packages_as_well_as_rubygems
    publish = release_workflow.fetch("jobs").fetch("publish")

    assert_equal "write", publish.fetch("permissions").fetch("packages"),
      "the publish job needs `packages: write` — the GitHub Packages push " \
      "authenticates with the job's GITHUB_TOKEN, and a job-level " \
      "permissions block replaces the workflow-level one"

    gpr_step = publish.fetch("steps").find do |step|
      step["run"].to_s.match?(/gem push.*?rubygems\.pkg\.github\.com/m)
    end
    refute_nil gpr_step,
      "no publish step pushes to rubygems.pkg.github.com — every built gem " \
      "must go to GitHub Packages as well as RubyGems (#107)"

    assert_match(/unset\s+GEM_HOST_API_KEY/, gpr_step["run"],
      "configure-rubygems-credentials exports GEM_HOST_API_KEY holding the " \
      "RubyGems token, and gem push prefers that env var over --key — " \
      "without the unset, the GitHub Packages push sends the RubyGems token " \
      "and gets a 401 (v0.4.4's publish failed exactly this way)")
  end

  # release.yml calls benchmark.yml as a reusable workflow, and reusable
  # calls receive none of the caller's secrets unless the job says
  # `secrets: inherit`. Without it, benchmark.yml's
  # `secrets.RELEASE_AUTOMATION_PAT || github.token` falls back to
  # GITHUB_TOKEN, the benchmark PR is authored by github-actions[bot], and
  # its CI run sits at action_required awaiting maintainer approval — zero
  # checks, auto-merge BLOCKED. Exactly what happened to the 0.4.4
  # benchmark PR (#146), with the secret itself set the whole time.
  def test_benchmark_workflow_call_inherits_secrets
    benchmark = release_workflow.fetch("jobs").fetch("benchmark")
    assert_equal "inherit", benchmark["secrets"],
      "the benchmark reusable-workflow call must declare `secrets: inherit` — " \
      "without it RELEASE_AUTOMATION_PAT is empty inside benchmark.yml and " \
      "its PR is opened with GITHUB_TOKEN, which needs approval to run CI"
  end

  private

  def workflow
    # No encoding argument needed, unlike the File.read above: Psych opens
    # with "r:bom|utf-8" regardless of the host locale.
    @workflow ||= YAML.load_file(CROSS_GEM_WORKFLOW)
  end

  def release_workflow
    @release_workflow ||= YAML.load_file(RELEASE_WORKFLOW)
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
