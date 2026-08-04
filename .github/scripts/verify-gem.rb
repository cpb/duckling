# frozen_string_literal: true

# Checks a built gem file, without installing it.
#
# This catches the faults that make RubyGems hand a consumer the wrong thing:
# a gem built for the wrong architecture, a gem missing a Ruby ABI it claims
# to support, and a required_ruby_version that offers the gem to the wrong set
# of Rubies. A cross-compile that silently targets the build host still exits 0
# and still writes a correctly named file, so the file name proves nothing.
#
# It does not load the gem. An ABI mismatch is invisible here and appears on
# the first call, so `.github/scripts/smoke-gem.rb` has to run as well.
#
# Run it against any built gem:
#
#   BUILT_GEM=pkg/duckling-0.3.0-x86_64-linux.gem \
#   EXPECTED_PLATFORM=x86_64-linux EXPECTED_ARCH=x86-64 \
#   EXPECTED_ABIS=3.2,3.3,3.4,4.0 ruby .github/scripts/verify-gem.rb
#
# Run it from the repository root: it reads duckling.gemspec for the floor
# that required_ruby_version must keep.

require "rubygems/package"
require "tmpdir"

built_gem = ENV.fetch("BUILT_GEM")
expected_platform = ENV.fetch("EXPECTED_PLATFORM")
expected_arch = ENV.fetch("EXPECTED_ARCH")
abis = ENV.fetch("EXPECTED_ABIS").split(",")

spec = Gem::Package.new(built_gem).spec
failures = []

unless spec.platform.to_s == expected_platform
  failures << "platform is #{spec.platform}, expected #{expected_platform}"
end

# duckling.gemspec builds its file list from `git ls-files`, which fails when
# the build runs against a git worktree — a worktree's .git is a file pointing
# somewhere the build container never mounted. The gem that comes out holds the
# compiled binaries and no Ruby at all, and every other check here passes on it.
unless spec.files.include?("lib/duckling.rb")
  failures << "carries no lib/duckling.rb, so nothing can require it — " \
    "duckling.gemspec's `git ls-files` came back empty. Build from a plain " \
    "clone rather than a worktree."
end

# required_ruby_version decides which Rubies RubyGems offers this gem to. It
# has to be wrong in one of two directions to do harm, so the checks below test
# those directions rather than compare against a fixed string.
#
# Too narrow, which rake-compiler produces on its own: RubyGems skips the gem
# and silently takes the source gem, so the install machine needs a Rust
# toolchain after all.
#
# Too wide: RubyGems offers the gem to a Ruby it carries no binary for, and the
# gem raises LoadError on require.
abis.each do |abi|
  next if spec.required_ruby_version.satisfied_by?(Gem::Version.new("#{abi}.0"))

  failures << "required_ruby_version #{spec.required_ruby_version} excludes " \
    "Ruby #{abi}, which this gem carries a binary for"
end

highest = abis.max_by { |abi| Gem::Version.new(abi) }
major, minor = highest.split(".").map(&:to_i)
beyond = "#{major}.#{minor + 1}.0"
if spec.required_ruby_version.satisfied_by?(Gem::Version.new(beyond))
  failures << "required_ruby_version #{spec.required_ruby_version} admits " \
    "Ruby #{beyond}, which this gem carries no binary for"
end

gemspec_floor = Gem::Specification.load("duckling.gemspec").required_ruby_version
below = gemspec_floor.requirements.map(&:last).min
unless spec.required_ruby_version.satisfied_by?(below)
  failures << "required_ruby_version #{spec.required_ruby_version} excludes " \
    "the gemspec floor #{below}"
end

Dir.mktmpdir do |dir|
  Gem::Package.new(built_gem).extract_files(dir)

  # A fat gem keeps each ABI in its own directory. A binary directly in
  # lib/duckling/ means only one ABI got built.
  found = Dir[File.join(dir, "lib/duckling/*/duckling.{so,bundle}")]
  built_abis = found.map { |path| File.basename(File.dirname(path)) }.sort

  if built_abis != abis.sort
    failures << "carries binaries for #{built_abis.inspect}, expected #{abis.sort.inspect}"
  end

  found.sort.each do |binary|
    name = "#{File.basename(File.dirname(binary))}/#{File.basename(binary)}"
    described = IO.popen(["file", "-b", binary], &:read).strip
    unless described.include?(expected_arch)
      failures << "#{name} is #{described}, expected #{expected_arch}"
    end
    puts "#{name}: #{described}"
  end
end

abort("Gem verification failed:\n- #{failures.join("\n- ")}") if failures.any?

puts "#{spec.full_name} verified (#{spec.required_ruby_version})"
