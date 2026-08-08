# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The manifest is what makes every other guarantee in the tz suite legible: if
# `problems` returns [] when it shouldn't, every leg goes green and the
# declarations become decoration. Same argument as stale_tolerant_test.rb, with
# more force — that helper at least fails loudly when it is wrong, while this
# one fails by staying quiet.
#
# `problems` is pure set arithmetic over four inputs, so most of this seeds
# them directly. The exception is `enforce!`, whose `exit 1` cannot be observed
# in the process it ends; that one runs a throwaway suite in a subprocess and
# reads the status the shell would.
class SkipManifestTest < Minitest::Test
  SEEDED = %i[@entries @executed @skipped @defined_tests @loaded_classes].freeze

  def setup
    super
    @saved = SEEDED.to_h { |name| [name, SkipManifest.instance_variable_get(name)] }
  end

  def teardown
    @saved.each { |name, value| SkipManifest.instance_variable_set(name, value) }
    super
  end

  # `executed`/`skipped` are what the run observed; `entries` is what the leg
  # declared. Everything defined is assumed to exist unless a case says
  # otherwise.
  def seed(entries:, executed: [], skipped: [], defined: nil)
    SkipManifest.instance_variable_set(:@entries, entries)
    SkipManifest.instance_variable_set(:@executed, executed)
    SkipManifest.instance_variable_set(:@skipped, skipped)
    SkipManifest.instance_variable_set(:@defined_tests, defined || entries.map(&:id) | executed | skipped)
    SkipManifest.instance_variable_set(:@loaded_classes, (defined || entries.map(&:id)).map { |id| id.split("#").first })
  end

  def entry(id, capability = nil)
    SkipManifest::Entry.new(id, capability)
  end

  def test_a_run_matching_its_manifest_reports_nothing
    seed(entries: [entry("T#a")], executed: ["T#a", "T#b"], skipped: ["T#a"])

    assert_empty SkipManifest.problems
  end

  def test_flags_a_skip_the_leg_did_not_declare
    seed(entries: [], executed: ["T#a"], skipped: ["T#a"], defined: ["T#a"])

    assert_equal 1, SkipManifest.problems.size
    assert_match(/T#a skipped, but the .* leg does not declare it/, SkipManifest.problems.first)
  end

  def test_flags_a_declared_entry_that_ran_to_completion
    seed(entries: [entry("T#a")], executed: ["T#a"], skipped: [])

    assert_equal 1, SkipManifest.problems.size
    assert_match(/T#a ran to completion/, SkipManifest.problems.first)
  end

  # A declared entry is only judged against what actually ran, so running one
  # file must not indict every test the run left out.
  def test_ignores_a_declared_entry_that_never_executed
    seed(entries: [entry("T#a")], executed: [], skipped: [])

    assert_empty SkipManifest.problems
  end

  # The subtlest of the four, and the reason `unless:` is still a two-way
  # check: the capability is present, so the test must have run. Skipping
  # anyway means something other than a missing capability stopped it — a
  # vacuous pass wearing a skip.
  def test_flags_a_conditional_entry_that_skipped_while_its_capability_was_present
    with_capability(present: true) do
      seed(entries: [entry("T#a", :greenland_2023_rules)], executed: ["T#a"], skipped: ["T#a"])

      assert_equal 1, SkipManifest.problems.size
      assert_match(/capability it is conditional on is present/, SkipManifest.problems.first)
    end
  end

  # The same entry on a database lacking the capability: skipping is correct
  # and must not be reported.
  def test_accepts_a_conditional_entry_that_skipped_while_its_capability_was_absent
    with_capability(present: false) do
      seed(entries: [entry("T#a", :greenland_2023_rules)], executed: ["T#a"], skipped: ["T#a"])

      assert_empty SkipManifest.problems
    end
  end

  def test_flags_a_declared_entry_naming_a_test_that_does_not_exist
    seed(entries: [entry("T#gone")], defined: ["T#a"])

    assert_equal 1, SkipManifest.problems.size
    assert_match(/T#gone is declared .* but no such test exists/, SkipManifest.problems.first)
  end

  # enforce! must fail the process even when every test passed — a green
  # minitest summary is exactly what it exists to override. Only observable
  # from outside, since it exits.
  def test_enforce_fails_the_process_on_an_undeclared_skip
    assert_equal 1, run_probe_suite(declared: false), "expected an undeclared skip to exit non-zero"
  end

  def test_enforce_leaves_a_matching_run_alone
    assert_equal 0, run_probe_suite(declared: true), "expected a declared skip to exit zero"
  end

  private

  # Forces the answer TZCapabilities would give, because no real answer is
  # available on every leg: each of the three capabilities is absent on at
  # least one of them, so a test keyed to a live probe would pass here and
  # fail there. The logic under test is set arithmetic and shouldn't care
  # which database is installed.
  def with_capability(present:)
    original = TZCapabilities.method(:supports?)
    swap = lambda do |implementation|
      verbose, $VERBOSE = $VERBOSE, nil
      TZCapabilities.define_singleton_method(:supports?, implementation)
      $VERBOSE = verbose
    end

    swap.call(->(_capability) { present })
    begin
      yield
    ensure
      swap.call(original)
    end
  end

  # Runs a one-test suite that skips, under a manifest that either declares
  # that skip or doesn't, and returns the child's exit status.
  def run_probe_suite(declared:)
    Dir.mktmpdir do |dir|
      declarations = declared ? ["SkipProbeTest#test_skips"] : []
      File.write("#{dir}/manifest.yml", {"always" => [], "probe" => declarations}.to_yaml)
      File.write("#{dir}/skip_probe_test.rb", <<~RUBY)
        require "test_helper"
        class SkipProbeTest < Minitest::Test
          def test_skips
            skip "deliberate, to exercise the manifest"
          end
        end
      RUBY

      env = {
        "DUCKLING_SKIP_MANIFEST" => "#{dir}/manifest.yml",
        "DUCKLING_TZ_LEG" => "probe",
        "DUCKLING_TZ_FULL_RUN" => "1"
      }
      command = [env, RbConfig.ruby, "-I#{__dir__}/../lib", "-I#{__dir__}", "#{dir}/skip_probe_test.rb"]
      system(*command, out: File::NULL, err: File::NULL)
      $?.exitstatus
    end
  end
end
