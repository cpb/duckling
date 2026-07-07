# frozen_string_literal: true

require "test_helper"

# One representative case per non-Time dimension, pinning the exact `:value`
# shape produced by the generic serde_magnus conversion (issue #90). Every
# dimension keeps serde's externally-tagged representation uniformly: the
# PascalCase `DimensionValue` tag wraps each payload (`{Numeral: 42.0}`,
# `{Url: {value:, domain:}}`), and measurement dimensions carry the nested
# `MeasurementValue` tag the same way (`{Temperature: {Value: {...}}}`) —
# one consistent tagged shape rather than a mix of unwrapped and tagged
# layers.
class DucklingParseDimensionsTest < Minitest::Test
  def entity_for(text, dim)
    results = Duckling.parse(text, locale: "en", dims: [dim])
    entity = results.find { |r| r[:dim] == dim.to_sym }
    refute_nil entity, "expected a #{dim.inspect} entity for #{text.inspect}, got: #{results.inspect}"
    entity
  end

  def test_number_value_is_a_tagged_float
    assert_equal({Numeral: 33.0}, entity_for("thirty three", "number")[:value])
  end

  def test_ordinal_value_is_a_tagged_integer
    assert_equal({Ordinal: 3}, entity_for("3rd", "ordinal")[:value])
  end

  def test_temperature_value_is_a_tagged_measurement
    assert_equal({Temperature: {Value: {value: 37.0, unit: "celsius"}}},
      entity_for("37 degrees Celsius", "temperature")[:value])
  end

  def test_distance_value_is_a_tagged_measurement
    assert_equal({Distance: {Value: {value: 3.0, unit: "kilometre"}}},
      entity_for("3 kilometers", "distance")[:value])
  end

  def test_volume_value_is_a_tagged_measurement
    assert_equal({Volume: {Value: {value: 1.0, unit: "litre"}}},
      entity_for("1 liter", "volume")[:value])
  end

  def test_quantity_value_includes_measurement_and_product
    assert_equal({Quantity: {measurement: {Value: {value: 5.0, unit: "pound"}}, product: "sugar"}},
      entity_for("5 pounds of sugar", "quantity")[:value])
  end

  def test_quantity_without_a_product_keeps_an_explicit_nil_product_key
    value = entity_for("2 grams", "quantity")[:value][:Quantity]
    assert value.key?(:product), "expected :product key to be present (serde emits Option::None as nil)"
    assert_nil value[:product]
    assert_equal({Value: {value: 2.0, unit: "gram"}}, value[:measurement])
  end

  def test_amount_of_money_value_is_a_tagged_measurement
    assert_equal({AmountOfMoney: {Value: {value: 42.5, unit: "USD"}}},
      entity_for("$42.50", "amount-of-money")[:value])
  end

  def test_measurement_interval_keeps_the_interval_tag
    assert_equal({AmountOfMoney: {Interval: {from: {value: 3.0, unit: "USD"}, to: {value: 5.0, unit: "USD"}}}},
      entity_for("between 3 and 5 dollars", "amount-of-money")[:value])
  end

  def test_email_value_is_the_tagged_address_string
    assert_equal({Email: "user@example.com"}, entity_for("user@example.com", "email")[:value])
  end

  def test_phone_number_value_is_the_tagged_normalized_digits_string
    assert_equal({PhoneNumber: "6507018887"}, entity_for("650-701-8887", "phone-number")[:value])
  end

  def test_url_value_includes_url_and_domain
    assert_equal({Url: {value: "http://www.bla.com", domain: "bla.com"}},
      entity_for("http://www.bla.com", "url")[:value])
  end

  def test_credit_card_number_value_includes_normalized_number_and_issuer
    assert_equal({CreditCardNumber: {value: "4111111111111111", issuer: "visa"}},
      entity_for("4111-1111-1111-1111", "credit-card-number")[:value])
  end

  def test_time_grain_value_is_a_tagged_snake_case_symbol
    assert_equal({TimeGrain: :second}, entity_for("second", "time-grain")[:value])
  end

  def test_duration_value_patches_grain_to_the_snake_case_symbol
    assert_equal({Duration: {value: 3, grain: :day, normalized_seconds: 259200}},
      entity_for("3 days", "duration")[:value])
  end
end
