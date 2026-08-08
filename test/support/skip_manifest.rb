# frozen_string_literal: true

require "yaml"

# Turns every skip in the suite into an assertion.
#
# Scope note, because the tz legs are what motivated this and the name could
# read narrower than it is: this governs **every** skip in the default suite,
# not only tz-capability ones. A new unconditional `skip` anywhere has to be
# declared in `always:` before a plain `bundle exec rake` passes. That is
# intended — a skip reads as a pass in a CI log, and nobody diffs a log — but
# it does mean an unrelated change can be failed by this file.
#
# `stale_tolerant` (test_helper.rb) exists so a test can keep asserting the
# real thing on a tz database that cannot possibly answer it, and skip instead
# of failing. On its own that is how coverage disappears quietly. So each leg
# declares, in test/skip_manifest.yml, exactly which tests it expects to skip
# — and this fails the build three ways:
#
# - A test skips that the leg did not declare. Something lost coverage.
# - A declared test runs to completion instead of skipping. The leg gained a
#   capability, and the manifest is now overstating what it costs.
# - A declared entry names a test that does not exist. A rename, a deletion,
#   or a typo — which would otherwise sit in the file forever, enforcing
#   nothing, since a test that never runs trips neither check above.
#
# Together those keep the manifest honest as databases move; a manifest that
# only ever grows would end up declaring skips that stopped happening years
# ago, and one that can name nothing would stop declaring anything at all.
#
# Only tests that actually executed are considered for the second check, so
# running a single file or a single test — `bin/test path/to/file.rb:42` —
# does not trip it for everything the run left out.
module SkipManifest
  PATH = File.expand_path("../skip_manifest.yml", __dir__)

  # Which leg's expectations to enforce. Defaults to the configuration a
  # plain `bundle exec rake` produces: the Gemfile installs current
  # tzinfo-data unless DUCKLING_TZINFO_DATA says otherwise.
  LEG = ENV.fetch("DUCKLING_TZ_LEG", "tzinfo-data")

  # Skips that are leg-independent — known upstream limitations characterized
  # elsewhere in the suite, which have nothing to do with tz data. Declared in
  # the manifest rather than exempted in code, so a *new* unconditional skip
  # still has to be added deliberately and shows up in a diff.
  ALWAYS_KEY = "always"

  # Set by the Rakefile's `test` task, which requires every test file before
  # applying any name filter — so under rake the set of defined tests is
  # complete even for `bin/test file.rb:42`, and an entry naming nothing can
  # be called stale with confidence. Absent for a bare
  # `ruby -Itest test/foo_test.rb`, where only one file's classes exist.
  FULL_RUN = ENV["DUCKLING_TZ_FULL_RUN"] == "1"

  module_function

  def executed
    @executed ||= []
  end

  def skipped
    @skipped ||= []
  end

  # Called from Minitest::Test#after_teardown, by which point the skip
  # exception is already recorded in the test's own `failures`.
  def observe(test)
    id = "#{test.class}##{test.name}"
    executed << id
    skipped << id if test.failures.any?(Minitest::Skip)
  end

  def expected
    @expected ||= begin
      manifest = YAML.safe_load_file(PATH)
      legs = manifest.keys - [ALWAYS_KEY]
      unless manifest.key?(LEG)
        raise "DUCKLING_TZ_LEG=#{LEG.inspect} is not declared in #{PATH} (declared legs: #{legs.inspect})"
      end

      Array(manifest[ALWAYS_KEY]) | Array(manifest[LEG])
    end
  end

  # Every "Class#method" minitest knows about, from the test classes loaded
  # into this process.
  def defined_tests
    @defined_tests ||= Minitest::Runnable.runnables.flat_map { |runnable|
      runnable.runnable_methods.map { |method| "#{runnable}##{method}" }
    }
  end

  def loaded_classes
    @loaded_classes ||= Minitest::Runnable.runnables.map(&:to_s)
  end

  # Declared entries that name no existing test.
  #
  # Outside a full run only entries whose *class* did load are judged, since
  # a class this process never loaded says nothing about whether the test
  # exists. Under rake every test file is required, so FULL_RUN lets a
  # misspelled class name be caught too.
  def stale
    expected.reject do |id|
      defined_tests.include?(id) ||
        (!FULL_RUN && !loaded_classes.include?(id.split("#").first))
    end
  end

  # Empty when the run matched the manifest; otherwise one line per
  # discrepancy, in the order a reader would want to act on them.
  def problems
    undeclared = skipped - expected
    declared_but_ran = (expected & executed) - skipped

    undeclared.map { |id|
      "#{id} skipped, but the #{LEG.inspect} leg does not declare it. " \
        "Add it to #{ALWAYS_KEY}: or #{LEG}: in #{PATH} if the lost coverage is intended."
    } + declared_but_ran.map { |id|
      "#{id} ran to completion, but the #{LEG.inspect} leg declares it as an expected skip. " \
        "Remove it from #{PATH} — the capability it waits for is present now."
    } + stale.map { |id|
      "#{id} is declared in #{PATH} but no such test exists. " \
        "It was renamed or removed; update the entry, or drop it."
    }
  end

  # Fails the process even when every test passed. A skip that nobody declared
  # is exactly the outcome a green log hides, so it has to be louder than the
  # log.
  def enforce!
    found = problems
    return if found.empty?

    warn ""
    warn "Skip manifest mismatch on the #{LEG.inspect} tz leg:"
    found.each { |problem| warn "  - #{problem}" }
    warn ""
    exit 1
  end
end
