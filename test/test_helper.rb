# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# The tz database under test is a CI axis, not a property of the host: this
# gem does not depend on tzinfo-data, so reference_zone: resolves against
# whichever database tzinfo found, and the two disagree. DUCKLING_TZINFO_DATA
# (see the Gemfile) chooses whether the gem is in the bundle at all;
# DUCKLING_ZONEINFO_DIR points at a specific compiled zoneinfo directory,
# which is how the stale-system leg reaches a state no released tzdata
# tarball is in. Set before duckling is required so nothing resolves a zone
# against the default source first.
if (zoneinfo_dir = ENV["DUCKLING_ZONEINFO_DIR"])
  require "tzinfo"
  TZInfo::DataSource.set(:zoneinfo, zoneinfo_dir)
end

require "duckling"

require "minitest/autorun"

require_relative "support/tz_capabilities"
require_relative "support/tz_fixtures"

# One line naming the tz database this run actually got, and what it turned
# out to be able to do. Two Ubuntu 24.04 images disagree about the
# backward-compat links, so a CI environment's name does not by itself tell
# you which capabilities were present — without this line, reconciling a
# capability test that didn't run against a CI log means guessing at the
# runner's tzdata packaging.
begin
  probes = TZCapabilities::CAPABILITIES.keys.map { |name| "#{name}=#{TZCapabilities.supports?(name)}" }
  warn "tz datasource: #{TZCapabilities.datasource_description}; #{probes.join(" ")}"
rescue TZInfo::DataSourceNotFound => error
  warn "tz datasource: none (#{error.message.lines.first.to_s.strip})"
end

# Strict expected-failure for known limitations that fail on every host
# (upstream grammar/ranking gaps — see test/duckling_comma_list_test.rb and
# test/duckling_parse_time_weekdays_test.rb). Runs the block — the assertions
# are the real ones, not a weakened variant — and converts a failure into a
# skip naming `reason`. A *pass* fails the test: a limitation that stops
# reproducing (an upstream fix, a ranking change) turns the suite red here
# rather than letting the wrapper rot into a permanent skip, and the red is
# the signal to drop the wrapper and keep the assertions.
#
# Only Minitest::Assertion is rescued, deliberately. Adding StandardError
# would launder any crash *before* the assertions — a NoMethodError from a
# :value shape drift, a Duckling::ShapeError, an ArgumentError from a keyword
# change — into "known upstream limitation", which is exactly the confusion
# the paragraph below rules out for the tz axis. The same logic disqualifies
# it here: a genuine regression must surface as a crash, not as a documented
# gap. Minitest::Assertion inherits from Exception rather than StandardError,
# so naming it is what makes the intended arm work at all.
#
# Minitest::Skip subclasses Minitest::Assertion, so a `skip` inside the block
# would otherwise be swallowed and re-emitted under `reason`, replacing the
# real explanation. Re-raised first.
#
# Deliberately *not* used for the tz-database axis: an environment-dependent
# test wrapped this way would convert a genuine regression into a skip just
# as happily as an absent capability, and nothing would notice. Those live in
# test/capabilities/ instead — see the loader at the bottom of this file.
def expect_failure(reason)
  yield
rescue Minitest::Skip
  raise
rescue Minitest::Assertion => error
  skip "#{reason} [#{error.class}: #{error.message.lines.first.to_s.strip}]"
else
  flunk "Unexpected pass — expected failure due to: #{reason}"
end

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00, a Tuesday), so relative expressions
# resolve to fixed, assertable values instead of drifting with the real clock.
# A real `Time` (not an Integer): `Native.parse`'s `reference_time:` requires
# a `Time`-like value (or something responding to `#to_time`) so its
# `utc_offset` can be threaded through to `Naive` results via
# `Context::timezone()` — an Integer can't carry an offset at all.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00")

# Parses `text` for `dim` and returns the first matching entity, failing the
# calling test if none is found. `reference_time:` and `reference_zone:` are
# threaded through for dims (like :time) whose resolution depends on an
# anchor moment or an IANA zone.
def entity_for(text, dim, reference_time: nil, reference_zone: nil)
  parse_kwargs = {locale: "en", dims: [dim.to_s]}
  parse_kwargs[:reference_time] = reference_time if reference_time
  parse_kwargs[:reference_zone] = reference_zone if reference_zone
  results = Duckling.parse(text, **parse_kwargs)
  entity = results.find { |r| r[:dim] == dim.to_sym }
  refute_nil entity, "expected a #{dim.inspect} entity for #{text.inspect}, got: #{results.inspect}"
  entity
end

# Issue #91: `:time`'s `:value` uses the same unified externally-tagged shape
# as the other 13 dimensions (#90) — every `TimePoint` (a `Single` result's
# primary `value`/each `values` entry, or an `Interval`'s `from`/`to`) is
# individually tagged `{Naive: {value:, grain:}}` or `{Instant: {value:, grain:}}`.
# This unwraps one tagged `TimePoint` hash down to its plain `{value:, grain:}`
# payload regardless of which of the two tags is present, since most
# call sites don't need to distinguish Naive from Instant.
def time_point(tagged)
  return flunk("expected a :Naive- or :Instant-tagged TimePoint, got: nil") if tagged.nil?
  tagged[:Naive] || tagged[:Instant] ||
    flunk("expected a :Naive- or :Instant-tagged TimePoint, got: #{tagged.inspect}")
end

# Unwraps a Single-shaped entity's primary tagged TimePoint down to its plain
# `{value:, grain:}` payload — see `time_point`.
def single_point(entity)
  single = entity[:value][:Time][:Single] ||
    flunk("Expected entity[:value][:Time] to be tagged :Single, got: #{entity[:value].inspect}")
  time_point(single[:value])
end

# Unwraps an Interval-shaped entity down to its {from:, to:} pair of plain
# `{value:, grain:}` payloads — see `time_point`.
def interval_points(entity)
  interval = entity[:value][:Time][:Interval] ||
    flunk("Expected entity[:value][:Time] to be tagged :Interval, got: #{entity[:value].inspect}")
  [time_point(interval[:from]), time_point(interval[:to])]
end

# Capability-gated tests live in test/capabilities/<capability>_test.rb and
# load only where the tz database in use can actually answer them: a test
# whose premise this database cannot meet never enters the run, instead of
# failing for want of the capability or — worse — passing vacuously. See
# "The tz-database axis" in AGENTS.md.
#
# The filename IS the declaration: supports? raises on a name that isn't in
# CAPABILITIES, so a typo'd file fails the run at load rather than silently
# never loading. The counterpart for synthesized states is
# test/environments/ — contract files invoked directly by the CI step that
# creates the state, never loaded here.
#
# This runs last so every helper above is already defined for the files it
# loads. A file invoked directly (`ruby -Itest
# test/capabilities/negative_dst_test.rb`) is skipped here to avoid a double
# load — it then runs regardless of the probe, which is the point of running
# one by hand.
# $VERBOSE is silenced around the requires: each capability file starts with
# its own `require "test_helper"` (so it can also be run directly), which is
# a circular require from here — harmless, but the suite runs with -w, and
# Ruby warns about it.
#
# A test/environments/ contract requires this helper too, and must NOT drag
# the capability suite in behind it: those steps ask one narrow question about
# an environment's setup, and a failing capability test there would redden a
# step named for the environment with a message about Dublin or Nuuk. The
# "never loaded by the suite" direction was accounted for; this is the
# reverse coupling.
running_environment_contract =
  File.expand_path($PROGRAM_NAME).start_with?(File.expand_path("environments", __dir__) + File::SEPARATOR)

Dir[File.expand_path("capabilities/*_test.rb", __dir__)].sort.each do |file|
  next if running_environment_contract
  next if File.expand_path(file) == File.expand_path($PROGRAM_NAME)

  next unless TZCapabilities.supports?(File.basename(file, "_test.rb").to_sym)

  verbose, $VERBOSE = $VERBOSE, nil
  begin
    require file
  ensure
    $VERBOSE = verbose
  end
end
