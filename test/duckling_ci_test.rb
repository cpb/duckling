# frozen_string_literal: true

require "test_helper"
require "yaml"

class DucklingCiTest < Minitest::Test
  CROSS_GEM_WORKFLOW = File.expand_path("../.github/workflows/cross-gem.yml", __dir__)
  RAKEFILE = File.expand_path("../Rakefile", __dir__)

  def test_native_extension_infrastructure
    ext_dir = File.join(__dir__, "../ext/duckling")

    assert File.exist?(File.join(ext_dir, "Cargo.toml")),
      "ext/duckling/Cargo.toml must exist — Rust crate not yet set up"

    cargo = File.read(File.join(ext_dir, "Cargo.toml"))
    assert_match(/\[lib\]/, cargo, "Cargo.toml must declare a [lib] section")
    assert_match(/crate-type.*cdylib/, cargo, "Cargo.toml must set crate-type = [\"cdylib\"]")
  end

  # A Ruby ABI needs a binary built for it, a metadata check that expects that
  # binary, and a smoke test that loads it on a real Ruby of that version. Those
  # three live in .github/workflows/cross-gem.yml, and CROSS_RUBY_ABIS in the
  # Rakefile derives the required_ruby_version ceiling from a fourth copy.
  #
  # Three of the four ways these drift apart already fail loudly, in
  # .github/scripts/verify-gem.rb. The smoke matrix is the exception: drop an
  # ABI from it and the gem still builds, still verifies, and still publishes,
  # with nothing having loaded that binary. An ABI mismatch is invisible to
  # every check that only reads a gem file, so losing the smoke test for an ABI
  # loses the only coverage it has.
  def test_every_cross_compiled_ruby_abi_is_verified_and_smoke_tested
    abis = normalize(rakefile_cross_ruby_abis)

    assert_equal abis, normalize(cross_gem_step.fetch("with").fetch("ruby-versions").split(",")),
      "`ruby-versions` builds a different ABI set than CROSS_RUBY_ABIS in the Rakefile"

    assert_equal abis, normalize(verify_step.fetch("env").fetch("EXPECTED_ABIS").split(",")),
      "EXPECTED_ABIS checks a different ABI set than CROSS_RUBY_ABIS in the Rakefile"

    assert_equal abis, normalize(job("smoke").fetch("strategy").fetch("matrix").fetch("ruby")),
      "the smoke job runs a different ABI set than CROSS_RUBY_ABIS in the Rakefile — " \
      "an ABI missing here ships in every gem without ever being loaded"
  end

  # Adding a platform takes four edits to cross-gem.yml: the build matrix, its
  # expected_arch pair, the smoke matrix, and a runner that can execute that
  # architecture. The build matrix alone is the edit that looks sufficient.
  def test_every_cross_compiled_platform_is_verified_and_smoke_tested
    built = job("cross_gems").fetch("strategy").fetch("matrix").fetch("platform").sort

    assert_equal built, job("smoke").fetch("strategy").fetch("matrix").fetch("platform").sort,
      "the smoke job covers different platforms than the cross-compile job — " \
      "a platform missing here ships without ever running on its own hardware"

    assert_equal built, include_map("cross_gems", "expected_arch").keys.sort,
      "every built platform needs an expected_arch, or `file(1)` verifies nothing for it"

    assert_equal built, include_map("smoke", "runner").keys.sort,
      "every smoke-tested platform needs a runner label; GitHub leaves a job " \
      "asking for a runner that does not exist queued rather than failing it"
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

  def verify_step
    step = job("cross_gems").fetch("steps").find { |s| s["env"]&.key?("EXPECTED_ABIS") }
    refute_nil step, "cross-gem.yml needs a step passing EXPECTED_ABIS to verify-gem.rb"
    step
  end

  # A matrix `include:` entry pairs a platform with one extra field.
  def include_map(job_name, field)
    job(job_name).fetch("strategy").fetch("matrix").fetch("include")
      .select { |entry| entry.key?(field) }
      .to_h { |entry| [entry.fetch("platform"), entry.fetch(field)] }
  end

  # The Rakefile requires rb_sys and defines tasks against a compiled
  # extension, so read the constant out of its source rather than loading it.
  def rakefile_cross_ruby_abis
    list = File.read(RAKEFILE)[/^CROSS_RUBY_ABIS = %w\[([^\]]+)\]/, 1]
    refute_nil list, "Rakefile must keep CROSS_RUBY_ABIS as a %w[] literal for this test to read"
    list.split
  end

  # YAML turns an unquoted 4.0 into a Float, and the order of the ABIs is a
  # matter of taste in each file. Neither is a drift worth failing over.
  def normalize(abis)
    abis.map(&:to_s).sort_by { |abi| Gem::Version.new(abi) }
  end
end
