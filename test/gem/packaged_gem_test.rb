# frozen_string_literal: true

require "minitest/autorun"
require "rubygems/package"
require "tmpdir"
require "fileutils"
require_relative "../../cross_targets"

# Checks the precompiled gems in pkg/, without installing them.
#
# This catches the faults that make RubyGems hand a consumer the wrong thing: a
# gem built for the wrong architecture, a gem missing a Ruby ABI it claims to
# support, and a required_ruby_version that offers the gem to the wrong set of
# Rubies. A cross-compile that silently targets the build host still exits 0 and
# still writes a correctly named file, so the file name proves nothing.
#
# Nothing here loads a gem, so an ABI mismatch is invisible to every test in
# this file. test/gem/installed_gem_test.rb is what finds those.
#
# Run it against whatever is in pkg/, with plain ruby, from the repository root:
#
#   ruby test/gem/packaged_gem_test.rb
#
# Populate pkg/ with `rake 'native_gem[<platform>]'`, or by downloading a
# cross-gem.yml run's artifacts (`gh run download <run-id> -D pkg`). A platform
# with no gem in pkg/ skips, so one built gem is enough to check that one.
class PackagedGemTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # The lowest released Ruby no gem carries a binary for.
  FIRST_UNBUILT_RUBY = Gem::Version.new("#{CrossTargets::FIRST_UNBUILT_ABI}.0")

  EXTRACTED = {}
  Minitest.after_run { EXTRACTED.each_value { |dir| FileUtils.remove_entry(dir) } }

  # Without this, a change to where oxidize-rb/actions/cross-gem writes the gem
  # would leave every test below skipping, and the CI job passing green with
  # nothing verified.
  def test_pkg_holds_at_least_one_precompiled_gem
    refute_empty Dir[File.join(ROOT, "pkg", "duckling-*-*.gem")],
      "no precompiled gem in pkg/ — build one with `rake 'native_gem[<platform>]'` " \
      "or download a cross-gem.yml run's artifacts into pkg/"
  end

  # Every platform below is spelled out rather than looped over, so a failure
  # names the platform it belongs to. The cost is that adding one to
  # cross_targets.rb and forgetting to add its tests here leaves it built,
  # shipped, and unchecked.
  def test_every_platform_in_cross_targets_has_its_own_tests
    missing = CrossTargets::PLATFORMS.keys.reject do |platform|
      self.class.method_defined?(:"test_#{platform.tr("-", "_")}_binaries_match_its_declared_architecture")
    end

    assert_empty missing, "#{missing.join(", ")} is in CrossTargets::PLATFORMS with no tests here"
  end

  def test_x86_64_linux_gem_is_built_for_x86_64_linux
    skip_unless_built "x86_64-linux"

    assert_equal "x86_64-linux", spec_for("x86_64-linux").platform.to_s
  end

  def test_x86_64_linux_gem_carries_the_ruby_library
    skip_unless_built "x86_64-linux"

    assert_carries_the_ruby_library "x86_64-linux"
  end

  def test_x86_64_linux_gem_carries_a_binary_for_every_ruby_abi
    skip_unless_built "x86_64-linux"

    assert_equal CrossTargets::RUBY_ABIS.sort, built_abis("x86_64-linux"),
      "x86_64-linux carries binaries for a different ABI set than cross_targets.rb lists"
  end

  def test_x86_64_linux_binaries_match_its_declared_architecture
    skip_unless_built "x86_64-linux"

    assert_architecture "x86_64-linux"
  end

  def test_x86_64_linux_gem_offers_itself_to_the_right_rubies
    skip_unless_built "x86_64-linux"

    assert_required_ruby_version "x86_64-linux"
  end

  def test_aarch64_linux_gem_is_built_for_aarch64_linux
    skip_unless_built "aarch64-linux"

    assert_equal "aarch64-linux", spec_for("aarch64-linux").platform.to_s
  end

  def test_aarch64_linux_gem_carries_the_ruby_library
    skip_unless_built "aarch64-linux"

    assert_carries_the_ruby_library "aarch64-linux"
  end

  def test_aarch64_linux_gem_carries_a_binary_for_every_ruby_abi
    skip_unless_built "aarch64-linux"

    assert_equal CrossTargets::RUBY_ABIS.sort, built_abis("aarch64-linux"),
      "aarch64-linux carries binaries for a different ABI set than cross_targets.rb lists"
  end

  def test_aarch64_linux_binaries_match_its_declared_architecture
    skip_unless_built "aarch64-linux"

    assert_architecture "aarch64-linux"
  end

  def test_aarch64_linux_gem_offers_itself_to_the_right_rubies
    skip_unless_built "aarch64-linux"

    assert_required_ruby_version "aarch64-linux"
  end

  def test_x86_64_darwin_gem_is_built_for_x86_64_darwin
    skip_unless_built "x86_64-darwin"

    assert_equal "x86_64-darwin", spec_for("x86_64-darwin").platform.to_s
  end

  def test_x86_64_darwin_gem_carries_the_ruby_library
    skip_unless_built "x86_64-darwin"

    assert_carries_the_ruby_library "x86_64-darwin"
  end

  def test_x86_64_darwin_gem_carries_a_binary_for_every_ruby_abi
    skip_unless_built "x86_64-darwin"

    assert_equal CrossTargets::RUBY_ABIS.sort, built_abis("x86_64-darwin"),
      "x86_64-darwin carries binaries for a different ABI set than cross_targets.rb lists"
  end

  def test_x86_64_darwin_binaries_match_its_declared_architecture
    skip_unless_built "x86_64-darwin"

    assert_architecture "x86_64-darwin"
  end

  def test_x86_64_darwin_gem_offers_itself_to_the_right_rubies
    skip_unless_built "x86_64-darwin"

    assert_required_ruby_version "x86_64-darwin"
  end

  def test_arm64_darwin_gem_is_built_for_arm64_darwin
    skip_unless_built "arm64-darwin"

    assert_equal "arm64-darwin", spec_for("arm64-darwin").platform.to_s
  end

  def test_arm64_darwin_gem_carries_the_ruby_library
    skip_unless_built "arm64-darwin"

    assert_carries_the_ruby_library "arm64-darwin"
  end

  def test_arm64_darwin_gem_carries_a_binary_for_every_ruby_abi
    skip_unless_built "arm64-darwin"

    assert_equal CrossTargets::RUBY_ABIS.sort, built_abis("arm64-darwin"),
      "arm64-darwin carries binaries for a different ABI set than cross_targets.rb lists"
  end

  def test_arm64_darwin_binaries_match_its_declared_architecture
    skip_unless_built "arm64-darwin"

    assert_architecture "arm64-darwin"
  end

  def test_arm64_darwin_gem_offers_itself_to_the_right_rubies
    skip_unless_built "arm64-darwin"

    assert_required_ruby_version "arm64-darwin"
  end

  private

  # duckling.gemspec builds its file list from `git ls-files`, which fails when
  # the build runs somewhere git cannot read the repository — a git worktree,
  # whose .git is a file naming a path the build container never mounted. The
  # gem that comes out holds the compiled binaries and no Ruby at all, and every
  # other test here passes on it.
  def assert_carries_the_ruby_library(platform)
    assert_includes spec_for(platform).files, "lib/duckling.rb",
      "#{platform} carries no lib/duckling.rb, so nothing can require it — " \
      "duckling.gemspec's `git ls-files` came back empty"
  end

  # `file(1)` is the only thing that distinguishes a real cross-compile from one
  # that silently targeted the build host, since both write the same file name.
  def assert_architecture(platform)
    expected_arch = CrossTargets::PLATFORMS.fetch(platform).fetch(:arch)

    binaries(platform).each do |binary|
      name = File.join(File.basename(File.dirname(binary)), File.basename(binary))
      described = IO.popen(["file", "-b", binary], &:read).strip
      puts "#{platform} #{name}: #{described}"

      assert_includes described, expected_arch,
        "#{platform} #{name} is #{described}, expected #{expected_arch}"
    end
  end

  # required_ruby_version decides which Rubies RubyGems offers this gem to, and
  # it does harm in two opposite directions.
  #
  # Too narrow, which rake-compiler produces on its own: RubyGems skips the gem
  # and silently takes the source gem, so the install machine needs a Rust
  # toolchain after all — the outcome these gems exist to avoid.
  #
  # Too wide: RubyGems offers the gem to a Ruby it carries no binary for, and
  # the gem raises LoadError on require.
  def assert_required_ruby_version(platform)
    requirement = spec_for(platform).required_ruby_version

    CrossTargets::RUBY_ABIS.each do |abi|
      assert requirement.satisfied_by?(Gem::Version.new("#{abi}.0")),
        "#{platform}'s required_ruby_version #{requirement} excludes Ruby #{abi}, " \
        "which this gem carries a binary for"
    end

    refute requirement.satisfied_by?(FIRST_UNBUILT_RUBY),
      "#{platform}'s required_ruby_version #{requirement} admits Ruby " \
      "#{FIRST_UNBUILT_RUBY}, which this gem carries no binary for"

    assert requirement.satisfied_by?(gemspec_floor),
      "#{platform}'s required_ruby_version #{requirement} excludes the gemspec " \
      "floor #{gemspec_floor}"
  end

  # The gemspec's own floor, which rake-compiler would otherwise overwrite with
  # a floor derived from the Rubies it cross-compiled against.
  #
  # Loading duckling.gemspec shells out to `git ls-files`, and RubyGems answers
  # nil rather than raising when that fails. Only this one assertion needs it,
  # so a checkout without git still runs every other test in this file.
  def gemspec_floor
    @gemspec_floor ||= begin
      spec = Gem::Specification.load(File.join(ROOT, "duckling.gemspec"))
      raise "could not load duckling.gemspec — is `git` on PATH?" if spec.nil?

      spec.required_ruby_version.requirements.map(&:last).min
    end
  end

  def skip_unless_built(platform)
    return if gem_path(platform)

    skip "no #{platform} gem in pkg/"
  end

  def gem_path(platform)
    Dir[File.join(ROOT, "pkg", "duckling-*-#{platform}.gem")].max
  end

  def spec_for(platform)
    Gem::Package.new(gem_path(platform)).spec
  end

  # A fat gem keeps each ABI in its own directory. A binary directly in
  # lib/duckling/ means only one ABI got built.
  def binaries(platform)
    Dir[File.join(extracted(platform), "lib/duckling/*/duckling.{so,bundle}")].sort
  end

  def built_abis(platform)
    binaries(platform).map { |path| File.basename(File.dirname(path)) }.sort
  end

  # The gems run 11-12.5 MB packed and unpack to roughly 40 MB, so extract each
  # one once for the whole class rather than once per test.
  def extracted(platform)
    EXTRACTED[platform] ||= Dir.mktmpdir("duckling-#{platform}").tap do |dir|
      Gem::Package.new(gem_path(platform)).extract_files(dir)
    end
  end
end
