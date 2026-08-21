# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Selects the tz database under test (see docs/tz-database-axis.md). Set
# before duckling is required so nothing resolves against the default first.
if (zoneinfo_dir = ENV["DUCKLING_ZONEINFO_DIR"])
  require "tzinfo"
  TZInfo::DataSource.set(:zoneinfo, zoneinfo_dir)
end

require "duckling"

require "minitest/autorun"

require_relative "support/tz_capabilities"
require_relative "support/tz_fixtures"
require_relative "support/wafer_matchers"

# Banner: which database this run got and which probes passed.
begin
  probes = TZCapabilities::CAPABILITIES.keys.map { |name| "#{name}=#{TZCapabilities.supports?(name)}" }
  warn "tz datasource: #{TZCapabilities.datasource_description}; #{probes.join(" ")}"
rescue TZInfo::DataSourceNotFound => error
  warn "tz datasource: none (#{error.message.lines.first.to_s.strip})"
end

# Strict expected-failure for known limitations that fail on every host.
# A failure reports as a skip naming `reason`; a pass flunks (drop the
# wrapper, keep the assertions). Only Minitest::Assertion is rescued — it
# inherits from Exception, and a wider rescue would launder a crash into
# "known limitation". Environment-dependent tests live in test/capabilities/.
# See docs/tz-database-axis.md.
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
# resolve to fixed, assertable values that do not drift with the real clock.
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

# Loads test/capabilities/<capability>_test.rb only where the probe passes
# (see docs/tz-database-axis.md). The filename is the declaration; supports?
# raises on an unknown name. Skipped for a file run directly (it then runs
# regardless of the probe) and for a test/environments/ contract (which must
# not drag the capability suite in behind it). $VERBOSE is silenced around
# the requires: each capability file re-requires this helper, a circular
# require the suite's -w would warn about.
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
