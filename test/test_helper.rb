# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duckling"

require "minitest/autorun"

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
