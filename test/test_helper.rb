# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duckling"

require "minitest/autorun"

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00), so relative expressions resolve to fixed,
# assertable values instead of drifting with the real clock.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00") unless defined?(REFERENCE_TIME)

# Parses `text` for `dim` and returns the first matching entity, failing the
# calling test if none is found.
def entity_for(text, dim)
  results = Duckling.parse(text, locale: "en", dims: [dim])
  entity = results.find { |r| r[:dim] == dim.to_sym }
  refute_nil entity, "expected a #{dim.inspect} entity for #{text.inspect}, got: #{results.inspect}"
  entity
end
