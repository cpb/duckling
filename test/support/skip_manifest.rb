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

  # A declared expectation. `capability` is nil for a plain entry, or the name
  # of a tz capability for a conditional one — see CONDITIONAL_NOTE.
  Entry = Struct.new(:id, :capability)

  # Why an entry may be conditional.
  #
  # A leg fixes which *datasource* answers, and for most properties that
  # settles what it can do: every Debian/Ubuntu host compiles rearguard
  # tzdata, so "no negative DST" follows from "host zoneinfo". The
  # backward-compat links do not follow. They moved to a separate
  # `tzdata-legacy` package, and whether a given image ends up with them is a
  # property of that image, not of the leg — two Ubuntu 24.04 systems
  # disagree: this repo's dev container (tzdata 2025b) resolves 497
  # identifiers and no `US/Eastern`, while a GitHub `ubuntu-latest` runner
  # (tzdata 2026b, no tzdata-legacy) resolves it fine.
  #
  # Declaring such a test as an unconditional skip asserts a fact about the
  # machine that the leg does not control, and the run fails wherever the
  # guess is wrong. `unless:` states the real relationship instead: expected
  # to skip when the capability is absent, expected to *run* when it is
  # present. Still a two-way check — and the "must run when present"
  # direction is the valuable one, since a tz test that runs to completion
  # without the capability it depends on is a vacuous pass.
  CONDITIONAL_NOTE = "unless:"

  def manifest
    @manifest ||= YAML.safe_load_file(PATH)
  end

  def entries
    @entries ||= begin
      legs = manifest.keys - [ALWAYS_KEY]
      unless manifest.key?(LEG)
        raise "DUCKLING_TZ_LEG=#{LEG.inspect} is not declared in #{PATH} (declared legs: #{legs.inspect})"
      end

      (Array(manifest[ALWAYS_KEY]) + Array(manifest[LEG])).map do |entry|
        next Entry.new(entry, nil) unless entry.is_a?(Hash)

        Entry.new(entry.fetch("test"), entry.fetch("unless"))
      end
    end
  end

  # Every declared test id, conditional or not. What the stale check judges:
  # an entry naming nothing is wrong regardless of any capability.
  def expected
    entries.map(&:id)
  end

  # Declared ids whose capability really is absent here, so they must skip.
  def expected_to_skip
    entries.reject { |entry| entry.capability && TZCapabilities.supports?(entry.capability) }.map(&:id)
  end

  # Declared ids whose capability is present here, so they must NOT skip.
  def expected_to_run
    (entries.map(&:id) - expected_to_skip)
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
    skipped_despite_capability = skipped & expected_to_run
    declared_but_ran = (expected_to_skip & executed) - skipped

    undeclared.map { |id|
      "#{id} skipped, but the #{LEG.inspect} leg does not declare it. " \
        "Add it to #{ALWAYS_KEY}: or #{LEG}: in #{PATH} if the lost coverage is intended."
    } + skipped_despite_capability.map { |id|
      "#{id} skipped, but the capability it is conditional on is present on " \
        "#{TZCapabilities.datasource_description}. It should have run — something " \
        "other than a missing capability made it skip."
    } + declared_but_ran.map { |id|
      "#{id} ran to completion, but the #{LEG.inspect} leg declares it as an expected skip. " \
        "Either the capability it waits for is present now — in which case give the entry " \
        "an `#{CONDITIONAL_NOTE}` condition or drop it — or the test stopped depending on it."
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
