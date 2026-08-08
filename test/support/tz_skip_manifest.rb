# frozen_string_literal: true

require "yaml"

# Turns every skip in the suite into an assertion.
#
# `stale_tolerant` (test_helper.rb) exists so a test can keep asserting the
# real thing on a tz database that cannot possibly answer it, and skip instead
# of failing. On its own that is how coverage disappears quietly: a skip reads
# as a pass in a CI log, and nobody diffs a log. So each leg declares, in
# test/tz_skip_manifest.yml, exactly which tests it expects to skip — and this
# fails the build both ways round:
#
# - A test skips that the leg did not declare. Something lost coverage.
# - A declared test runs to completion instead of skipping. The leg gained a
#   capability, and the manifest is now overstating what it costs.
#
# The second direction is what keeps the manifest honest as databases move; a
# manifest that only ever grows would end up declaring skips that stopped
# happening years ago.
#
# Only tests that actually executed are considered, so running a single file
# or a single test — `bin/test path/to/file.rb:42` — does not trip the
# "declared but ran" check for everything the run left out.
module TZSkipManifest
  PATH = File.expand_path("../tz_skip_manifest.yml", __dir__)

  # Which leg's expectations to enforce. Defaults to the configuration a
  # plain `bundle exec rake` produces: the Gemfile installs current
  # tzinfo-data unless DUCKLING_TZINFO_DATA says otherwise.
  LEG = ENV.fetch("DUCKLING_TZ_LEG", "tzinfo-data")

  # Skips that are leg-independent — known upstream limitations characterized
  # elsewhere in the suite, which have nothing to do with tz data. Declared in
  # the manifest under `always:` rather than exempted here, so a *new*
  # unconditional skip still has to be added deliberately and shows up in a
  # diff.
  ALWAYS_KEY = "always"

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
