# frozen_string_literal: true

# What the precompiled gems are built for.
#
# The Rakefile, the gem-level test suites in test/gem/, and
# test/duckling_ci_test.rb all read this. .github/workflows/cross-gem.yml
# cannot — YAML has no way to require Ruby — so it restates the same matrix
# in four fields, and test/duckling_ci_test.rb fails when any of them drifts
# from this file.
module CrossTargets
  # Ruby ABIs each precompiled gem carries a binary for.
  #
  # rb-sys reads Ruby's internal object layout through the headers it compiles
  # against. A binary understands only the Ruby that built it, so a fat gem
  # needs one per ABI and lib/duckling.rb loads the running Ruby's.
  #
  # The rbsys/<platform> images carry the toolchains for these ABIs. Check
  # /usr/local/rake-compiler/config.yml in the image before adding one. A Ruby
  # newer than every ABI here takes the source gem, which compiles its own
  # binary.
  RUBY_ABIS = %w[3.2 3.3 3.4 4.0].freeze

  # Platforms the gems are built for.
  #
  # arch: what `file(1)` must report for that platform's compiled binaries. A
  # cross-compile that silently targets the build host still exits 0 and still
  # writes a correctly *named* artifact, so the platform name proves nothing.
  #
  # runner: a GitHub runner image that can execute that architecture, for the
  # smoke job. The label must name a *live* image: GitHub does not fail a job
  # that asks for a retired one, it leaves the job queued forever, so the run
  # never reports at all.
  #
  # macos-15-intel is the last x86_64 macOS image; GitHub drops x86_64 macOS
  # entirely once macos-15 retires, announced for fall 2027. Move to
  # macos-26-intel before then. Once no runner can execute an x86_64-darwin
  # gem, reconsider shipping one.
  PLATFORMS = {
    "x86_64-linux" => {arch: "x86-64", runner: "ubuntu-latest"},
    "aarch64-linux" => {arch: "aarch64", runner: "ubuntu-24.04-arm"},
    "x86_64-darwin" => {arch: "x86_64", runner: "macos-15-intel"},
    "arm64-darwin" => {arch: "arm64", runner: "macos-latest"}
  }.freeze

  # The first Ruby minor above every built ABI.
  FIRST_UNBUILT_ABI = begin
    major, minor = RUBY_ABIS.max_by { |abi| Gem::Version.new(abi) }.split(".").map(&:to_i)
    "#{major}.#{minor + 1}"
  end

  # The ceiling each precompiled gem's required_ruby_version carries.
  #
  # RubyGems must skip a precompiled gem on a Ruby it holds no binary for and
  # take the source gem, which compiles a matching binary at install time.
  # Without this cap RubyGems installs a gem with no usable binary, and the
  # gem raises LoadError on require.
  ABI_CEILING = "#{FIRST_UNBUILT_ABI}.dev"
end
