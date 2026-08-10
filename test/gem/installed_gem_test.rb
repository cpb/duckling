# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../cross_targets"

gem "duckling"
require "duckling"

# Exercises an *installed* duckling gem the way a consumer does.
#
# rb-sys reads Ruby's internal object layout through the headers it compiles
# against, so a binary built for one Ruby ABI misreads objects from another, and
# magnus then rejects a genuine Time as not a Time. A gem can hold a correctly
# named binary, for the right architecture, and still fail on the first call. No
# amount of reading the gem file finds that — only a real require and a real
# call do.
#
# Run it against any Ruby, on any machine, after `gem install`. Validate against
# an environment without a Rust toolchain, run it in a plain Ruby container:
#
#   docker run --rm --platform linux/amd64 -v "$PWD:/w" -w /w ruby:3.3-slim \
#     bash -c 'gem install --no-document ./pkg/duckling-*-x86_64-linux.gem &&
#              ruby test/gem/installed_gem_test.rb'
#
# Run it with plain `ruby`, never through rake or bundler. This checkout's
# Gemfile declares `gemspec` and Minitest::TestTask puts lib/ on the load path,
# and either one shadows the installed gem with the source sitting next to this
# file — which is the one thing this suite exists to rule out. It runs on the
# minitest every CRuby bundles, so no `gem install minitest` either: minitest 6
# pulls in prism, a native extension the container above cannot build.
class InstalledGemTest < Minitest::Test
  SPEC = Gem::Specification.find_by_name("duckling")
  BINARY = $LOADED_FEATURES.grep(/duckling\.(so|bundle)$/).first

  # RubyGems falls back to the source gem whenever it will not take a
  # precompiled one, and the source gem compiles a binary that works. That is a
  # passing run of every test below, from a gem that would have failed to
  # install on a machine with no Rust toolchain.
  def test_a_precompiled_gem_resolved
    refute_equal "ruby", SPEC.platform.to_s,
      "resolved the source gem, so nothing precompiled was tested"

    assert_includes CrossTargets::PLATFORMS.keys, SPEC.platform.to_s
  end

  # Gem::Platform#=~ rather than ==: the darwin gems are deliberately
  # unversioned, and Gem::Platform.local carries a Darwin major version.
  def test_the_resolved_gem_matches_this_machine
    assert Gem::Platform.local =~ SPEC.platform,
      "resolved #{SPEC.platform} on #{Gem::Platform.local}"
  end

  # A stray build in the working directory would otherwise pass every test
  # below while the gem's own binary went untested.
  def test_the_loaded_binary_belongs_to_the_gem
    refute_nil BINARY, "no compiled binary was loaded"

    assert BINARY.start_with?(SPEC.gem_dir),
      "loaded #{BINARY}, which is outside the gem at #{SPEC.gem_dir}"
  end

  # A precompiled gem carries one binary per ABI. Loading the plain path means
  # the loader in lib/duckling.rb missed this Ruby's directory and fell back.
  def test_the_loaded_binary_is_this_rubys_abi
    abi = RUBY_VERSION[/\d+\.\d+/]

    assert_includes BINARY, "/#{abi}/",
      "loaded #{BINARY}, which is not this Ruby's #{abi} ABI directory"
  end

  def test_parse_without_reference_time
    refute_nil Duckling.parse("tomorrow at 3pm", dims: ["time"]).first
  end

  # The regression this suite exists for. reference_time: is the only public
  # entrypoint that converts a Ruby Time into a Rust type, so it is the call an
  # ABI mismatch breaks first.
  def test_parse_with_reference_time
    entity = Duckling.parse(
      "tomorrow at 3pm",
      dims: ["time"],
      reference_time: Time.new(2026, 8, 4, 9, 0, 0, "-04:00")
    ).first
    refute_nil entity

    resolved = entity[:value][:Time][:Single][:value][:Naive][:value]

    assert_kind_of Time, resolved
    assert_equal "2026-08-05 15:00", resolved.strftime("%Y-%m-%d %H:%M")
  end

  # reference_zone: crosses back the other way, reading Time objects the native
  # call produced.
  #
  # Needs a tz database the *host* provides (the gem does not depend on
  # tzinfo-data). A scratch or distroless container has none: skip, since the
  # absence is the environment's, not the gem's.
  def test_parse_with_reference_zone
    begin
      TZInfo::DataSource.get
    rescue TZInfo::DataSourceNotFound
      skip "no tz database on this host; reference_zone: needs zoneinfo files or the tzinfo-data gem"
    end

    entity = Duckling.parse(
      "tomorrow at 3pm",
      dims: ["time"],
      reference_time: Time.new(2026, 8, 4, 9, 0, 0, "-04:00"),
      reference_zone: "America/New_York"
    ).first

    refute_nil entity
  end

  # A non-time dimension goes through serde_magnus rather than the hand-written
  # Time patching, so it fails independently of the tests above.
  def test_parse_a_non_time_dimension
    entity = Duckling.parse("42 dollars", dims: ["amount-of-money"]).first
    refute_nil entity

    assert_in_delta 42.0, entity[:value][:AmountOfMoney][:Value][:value]
  end
end
