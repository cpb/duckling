# frozen_string_literal: true

require "test_helper"

VALID_GRAINS = %i[second minute hour day week month quarter year].freeze

class DucklingApiTest < Minitest::Test
  def test_parse_returns_array
    assert_kind_of Array, Duckling.parse("tomorrow", locale: "en")
  end
end

class DucklingEntityShapeTest < Minitest::Test
  def test_parse_result_shape
    results = Duckling.parse("at 3pm", locale: "en")
    assert results.size > 0, "Expected at least one result from Duckling.parse"
    first = results.first
    assert first.key?(:body),  "Expected result to have :body key"
    assert first.key?(:start), "Expected result to have :start key"
    assert first.key?(:end),   "Expected result to have :end key"
    assert first.key?(:dim),   "Expected result to have :dim key"
    assert first.key?(:value), "Expected result to have :value key"
    value = first[:value]
    assert_kind_of Hash, value, "Expected :value to be a Hash"
    assert value.key?(:type),  "Expected :value to have :type key"
    assert value.key?(:value), "Expected :value to have :value key"
    assert value.key?(:grain), "Expected :value to have :grain key"
  end
end

class DucklingTimeExtractionTest < Minitest::Test
  def test_parses_time_dimension
    results = Duckling.parse("tomorrow", locale: "en")
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow'"
    assert_includes VALID_GRAINS, time_entity[:value][:grain],
      "Expected grain to be one of #{VALID_GRAINS.inspect}"
  end
end

class DucklingParityTest < Minitest::Test
  def test_parity_with_wafer_inc_duckling
    results = Duckling.parse("Call me tomorrow", locale: "en")
    assert_operator results.size, :>=, 1, "expected at least one entity for 'Call me tomorrow'"
    entity = results.find { |r| r[:body] == "tomorrow" }
    refute_nil entity, "expected an entity with body: 'tomorrow'"
    assert_equal :time,  entity[:dim]
    assert_equal :value, entity[:value][:type]
    assert_equal :day,   entity[:value][:grain]
    assert_match(/\A\d{4}-\d{2}-\d{2}/, entity[:value][:value],
      "expected :value to be an ISO8601 date string starting with YYYY-MM-DD")
    assert_kind_of Array, entity[:value][:values]
    assert entity[:value][:values].size > 0, "expected :values to be a non-empty Array"
  end
end

class DucklingIntervalTest < Minitest::Test
  def test_parses_interval
    results = Duckling.parse("from 3pm to 5pm", locale: "en")
    assert results.size > 0
    entity = results.first
    assert_equal :time,     entity[:dim]
    assert_equal :interval, entity[:value][:type]
    assert entity[:value].key?(:from), "interval value should have :from"
    assert entity[:value].key?(:to),   "interval value should have :to"
    assert_equal :hour, entity[:value][:from][:grain]
  end
end

class DucklingVersionTest < Minitest::Test
  def test_version_is_0_2_0
    assert_equal "0.2.0", Duckling::VERSION
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
