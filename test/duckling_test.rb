# frozen_string_literal: true

require "test_helper"

VALID_GRAINS = %i[second minute hour day week month quarter year].freeze

# Matches the reference time used throughout the pyduckling / wafer-inc-duckling
# corpora (2013-02-12T04:30:00-02:00), so relative expressions resolve to fixed,
# assertable values instead of drifting with the real clock.
REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i

class DucklingApiTest < Minitest::Test
  def test_parse_returns_array
    assert_kind_of Array, Duckling.parse("tomorrow", locale: "en")
  end
end

class DucklingEntityShapeTest < Minitest::Test
  def test_parse_result_shape
    results = Duckling.parse("at 3pm", locale: "en", reference_time: REFERENCE_TIME)
    assert results.size > 0, "Expected at least one result from Duckling.parse"
    first = results.first
    assert_kind_of Duckling::Entity, first
    assert_equal "at 3pm", first.body
    assert_kind_of Integer, first.start
    assert_kind_of Integer, first.end
    assert_equal :time, first.dim
    assert_kind_of Duckling::TimeValue::Single, first.value
    time_point = first.value.value
    assert_kind_of Duckling::TimePoint::Naive, time_point
    assert_equal :hour, time_point.grain
    assert_equal "2013-02-12T15:00:00", time_point.value
  end
end

class DucklingTimeExtractionTest < Minitest::Test
  def test_parses_time_dimension
    results = Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    time_entity = results.find { |r| r.dim == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow'"
    grain = time_entity.value.value.grain
    assert_includes VALID_GRAINS, grain, "Expected grain to be one of #{VALID_GRAINS.inspect}"
    assert_equal :day, grain
    assert_equal "2013-02-13T00:00:00", time_entity.value.value.value
  end
end

class DucklingParityTest < Minitest::Test
  def test_parity_with_wafer_inc_duckling
    results = Duckling.parse("Call me tomorrow", locale: "en", reference_time: REFERENCE_TIME)
    assert_operator results.size, :>=, 1, "expected at least one entity for 'Call me tomorrow'"
    entity = results.find { |r| r.body == "tomorrow" }
    refute_nil entity, "expected an entity with body: 'tomorrow'"
    assert_equal :time, entity.dim
    assert_kind_of Duckling::TimeValue::Single, entity.value
    assert_equal :day, entity.value.value.grain
    assert_equal "2013-02-13T00:00:00", entity.value.value.value
    assert_kind_of Array, entity.value.values
    assert entity.value.values.size > 0, "expected values to be a non-empty Array"
  end
end

class DucklingIntervalTest < Minitest::Test
  def test_parses_interval
    results = Duckling.parse("from 3pm to 5pm", locale: "en", reference_time: REFERENCE_TIME)
    assert results.size > 0
    entity = results.first
    assert_equal :time, entity.dim
    assert_kind_of Duckling::TimeValue::Interval, entity.value
    refute_nil entity.value.from, "interval value should have a from bound"
    refute_nil entity.value.to, "interval value should have a to bound"
    assert_equal :hour, entity.value.from.grain
    assert_equal "2013-02-12T15:00:00", entity.value.from.value
    assert_equal :hour, entity.value.to.grain
    # duckling represents interval :to as the exclusive hour boundary, not the
    # literal named time — "5pm" (17:00) surfaces as 18:00. Verified against
    # wafer-inc-duckling's own tests/time_corpus.rs (e.g. "3-4pm" -> to 17:00).
    assert_equal "2013-02-12T18:00:00", entity.value.to.value
  end
end

class DucklingNoGrainTest < Minitest::Test
  # Grain::NoGrain is used internally while resolving TimeForm::Now (see
  # wafer-inc-duckling's dimensions/time/mod.rs), but is itself normalized to
  # Grain::Second before a resolved Entity's TimePoint is ever built, so no
  # natural-language input reaches it in practice. Pin the parity-table entry
  # directly instead: a naive `.downcase.to_sym` on serde's bare "NoGrain"
  # string would give :nograin, not the correct :no_grain.
  def test_no_grain_symbolizes_correctly
    assert_equal :no_grain, Duckling::Entities.grain_symbol("NoGrain")
  end
end

class DucklingNumeralDimTest < Minitest::Test
  def test_numeral_dim_symbolizes_to_number_not_numeral
    results = Duckling.parse("forty two", locale: "en", dims: ["number"])
    entity = results.find { |r| r.dim == :number }
    refute_nil entity, "expected a :number dimension result"
    assert_equal 42.0, entity.value
  end
end

class DucklingEmailDimTest < Minitest::Test
  def test_email_dim_has_a_populated_value
    results = Duckling.parse("user@example.com", locale: "en", dims: ["email"])
    entity = results.find { |r| r.dim == :email }
    refute_nil entity, "expected an :email dimension result"
    assert_equal "user@example.com", entity.value
  end
end

class DucklingVersionTest < Minitest::Test
  def test_version_is_0_3_0
    assert_equal "0.3.0", Duckling::VERSION
  end
end

class DucklingCiTest < Minitest::Test
  def test_native_extension_infrastructure
    ext_dir = File.join(__dir__, "../ext/duckling")

    assert File.exist?(File.join(ext_dir, "Cargo.toml")),
      "ext/duckling/Cargo.toml must exist — Rust crate not yet set up"

    cargo = File.read(File.join(ext_dir, "Cargo.toml"))
    assert_match(/\[lib\]/, cargo, "Cargo.toml must declare a [lib] section")
    assert_match(/crate-type.*cdylib/, cargo, "Cargo.toml must set crate-type = [\"cdylib\"]")
  end
end
