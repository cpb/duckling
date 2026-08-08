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
require_relative "support/skip_manifest"

module Minitest
  class Test
    # Every executed test reports itself, so SkipManifest can hold the run to
    # what its leg declared. after_teardown runs late enough that a skip is
    # already recorded in `failures`.
    def after_teardown
      super
      SkipManifest.observe(self)
    end
  end
end

Minitest.after_run { SkipManifest.enforce! }

# Runs the block unguarded — its assertions are the real ones, not a weakened
# variant — and converts a failure into a *named* skip only when TZCapabilities
# confirms the tz database in use genuinely cannot answer `capability`.
# Anything else re-raises.
#
# Deliberately a rescue rather than a pre-guard. A pre-guard skips before
# learning anything, so a database that would have passed anyway gets counted
# as lost coverage, and the manifest ends up overstating the cost of a leg.
# Rescuing means the only skips recorded are ones where the assertion really
# did fail and the capability really is absent.
#
# Three failure shapes reach here, and they are not interchangeable:
#
# - A Minitest::Assertion, when the database resolves the zone and answers
#   with different rules. The stale-vintage case.
# - An ArgumentError out of timezone_for, when the identifier is missing
#   outright. The backward-compat-links case.
# - An ArgumentError out of verify_reference_time_offset!, when the zone
#   exists but sits at a different offset than the test's reference_time:
#   asserts. This is the one that actually fires for America/Nuuk on the
#   stale legs — pre-2023a Greenland is -03:00 on 2026-03-28, so the block
#   dies on the offset mismatch before reaching a single assertion.
#
# ARGUMENT_ERRORS keeps that third case from making the rescue a blanket
# amnesty. Without it, *any* ArgumentError raised anywhere in the block
# becomes a manifest-approved skip on a leg lacking the capability — an
# invalid locale:/dims: value after a refactor, a regression in the offset
# check itself, a bad Time.new in the test's own setup. All of those raise
# plain ArgumentError, and none has anything to do with the tz database. Both
# tz-related messages name the keyword that produced them; "unsupported
# locale:"/"unsupported dimension:" do not.
ARGUMENT_ERRORS_WORTH_SKIPPING = /reference_zone|reference_time/

def stale_tolerant(capability)
  yield
rescue Minitest::Assertion, ArgumentError => error
  raise if error.is_a?(Minitest::Skip)
  raise if error.is_a?(ArgumentError) && !error.message.match?(ARGUMENT_ERRORS_WORTH_SKIPPING)
  raise if TZCapabilities.supports?(capability)

  skip "#{capability} is absent from #{TZCapabilities.datasource_description}: " \
    "#{error.message.lines.first.to_s.strip}"
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
