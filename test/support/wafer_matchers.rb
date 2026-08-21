# frozen_string_literal: true

# Assertions for the generated wafer corpus tests under test/wafer/.
#
# Each one mirrors the matching `check_*` helper in wafer-inc/duckling's
# tests/*_corpus.rs. Three rules carry over from those checkers and are easy
# to get wrong. See docs/wafer-corpus.md.
#
# - A measurement Interval matches when EITHER bound matches value and unit.
# - An interval's expected grain has to appear on one leg, not on both.
# - Floats compare with a 0.01 tolerance.
#
# Every assertion is `.any?` over the entities the parse returned: the corpus
# states that a reading is present, not that it is the only one.
module WaferMatchers
  # The time corpora anchor every relative expression on one Tuesday. The two
  # named contexts sit inside a weekend, which is what this/next/last weekend
  # resolution turns on.
  REFERENCE_TIMES = {
    "default" => Time.new(2013, 2, 12, 4, 30, 0, "-02:00"),
    "saturday" => Time.new(2013, 2, 9, 10, 0, 0, "-02:00"),
    "friday_evening" => Time.new(2013, 2, 8, 20, 0, 0, "-02:00")
  }.freeze

  # Upstream compares f64s with `(a - b).abs() < 0.01`.
  TOLERANCE = 0.01

  def assert_numeral(text, expected)
    assert_dimension "number", text, "numeral #{expected}" do |value|
      close?(value[:Numeral], expected)
    end
  end

  def assert_ordinal(text, expected)
    assert_dimension "ordinal", text, "ordinal #{expected}" do |value|
      value[:Ordinal] == expected
    end
  end

  def assert_email(text, expected)
    assert_dimension "email", text, "email #{expected.inspect}" do |value|
      value[:Email] == expected
    end
  end

  def assert_no_email(text)
    refute_dimension "email", text
  end

  def assert_url(text, expected, domain)
    assert_dimension "url", text, "url #{expected.inspect} domain #{domain.inspect}" do |value|
      (url = value[:Url]) && url[:value] == expected && url[:domain] == domain
    end
  end

  def assert_no_url(text)
    refute_dimension "url", text
  end

  def assert_phone(text, expected)
    assert_dimension "phone-number", text, "phone number #{expected.inspect}" do |value|
      value[:PhoneNumber] == expected
    end
  end

  def assert_no_phone(text)
    refute_dimension "phone-number", text
  end

  def assert_credit_card(text, expected, issuer)
    assert_dimension "credit-card-number", text, "card #{expected.inspect} issuer #{issuer.inspect}" do |value|
      (card = value[:CreditCardNumber]) && card[:value] == expected && card[:issuer] == issuer
    end
  end

  def assert_no_credit_card(text)
    refute_dimension "credit-card-number", text
  end

  def assert_duration(text, expected, grain)
    assert_dimension "duration", text, "duration #{expected} #{grain}" do |value|
      (duration = value[:Duration]) && duration[:value] == expected && duration[:grain] == grain
    end
  end

  def assert_no_duration(text)
    refute_dimension "duration", text
  end

  def assert_money(text, expected, unit)
    assert_measurement "amount-of-money", :AmountOfMoney, text, expected, unit
  end

  def assert_distance(text, expected, unit)
    assert_measurement "distance", :Distance, text, expected, unit
  end

  def assert_volume(text, expected, unit)
    assert_measurement "volume", :Volume, text, expected, unit
  end

  def assert_temperature(text, expected, unit)
    assert_measurement "temperature", :Temperature, text, expected, unit
  end

  def assert_quantity(text, expected, unit)
    assert_dimension "quantity", text, "quantity #{expected} #{unit}" do |value|
      (quantity = value[:Quantity]) && measurement?(quantity[:measurement], expected, unit)
    end
  end

  def assert_quantity_with_product(text, expected, unit, product)
    assert_dimension "quantity", text, "quantity #{expected} #{unit} of #{product.inspect}" do |value|
      quantity = value[:Quantity]
      quantity && quantity[:product] == product && measurement?(quantity[:measurement], expected, unit)
    end
  end

  def assert_time_naive(text, expected, grain)
    assert_time_point text, :Naive, expected, grain
  end

  def assert_time_instant(text, expected, grain)
    assert_time_point text, :Instant, expected, grain
  end

  def assert_time_interval(text, from, to, grain, context: "default")
    assert_dimension "time", text, "interval #{from.inspect} to #{to.inspect} grain #{grain}", context: context do |value|
      interval = value.dig(:Time, :Interval)
      next false unless interval && interval[:from] && interval[:to]
      near = leaf(interval[:from])
      far = leaf(interval[:to])
      # Upstream accepts the grain on either leg, not on both.
      wall_clock(near[:value]) == from && wall_clock(far[:value]) == to &&
        [near[:grain], far[:grain]].include?(grain)
    end
  end

  def assert_time_open_interval_after(text, expected, grain)
    assert_open_interval text, :from, :to, expected, grain
  end

  def assert_time_open_interval_before(text, expected, grain)
    assert_open_interval text, :to, :from, expected, grain
  end

  def assert_no_time(text)
    refute_dimension "time", text, context: "default"
  end

  private

  def assert_time_point(text, tag, expected, grain)
    assert_dimension "time", text, "#{tag} #{expected.inspect} grain #{grain}", context: "default" do |value|
      point = value.dig(:Time, :Single, :value, tag)
      point && wall_clock(point[:value]) == expected && point[:grain] == grain
    end
  end

  def assert_open_interval(text, open_leg, closed_leg, expected, grain)
    description = "open interval (#{open_leg}) #{expected.inspect} grain #{grain}"
    assert_dimension "time", text, description, context: "default" do |value|
      interval = value.dig(:Time, :Interval)
      next false unless interval && interval[open_leg] && interval[closed_leg].nil?
      point = leaf(interval[open_leg])
      wall_clock(point[:value]) == expected && point[:grain] == grain
    end
  end

  def assert_measurement(dim, tag, text, expected, unit)
    assert_dimension dim, text, "#{dim} #{expected} #{unit}" do |value|
      measurement?(value[tag], expected, unit)
    end
  end

  def assert_dimension(dim, text, description, context: nil, &matcher)
    values = wafer_parse(dim, text, context).map { |entity| entity[:value] }
    assert values.any?(&matcher),
      "Expected #{description} for #{text.inspect}, got: #{values.inspect}"
  end

  def refute_dimension(dim, text, context: nil)
    values = wafer_parse(dim, text, context).map { |entity| entity[:value] }
    assert_empty values, "Expected NO #{dim} for #{text.inspect}"
  end

  # Only the time corpora depend on an anchor moment. The rest call upstream's
  # parse_en, which supplies its own default context.
  def wafer_parse(dim, text, context)
    kwargs = {locale: "en", dims: [dim]}
    kwargs[:reference_time] = REFERENCE_TIMES.fetch(context) if context
    Duckling.parse(text, **kwargs)
  end

  # Mirrors the Rust measurement checkers: a Value matches on value and unit,
  # and an Interval matches when either bound does.
  def measurement?(measurement, expected, unit)
    return false unless measurement

    if (single = measurement[:Value])
      measurement_point?(single, expected, unit)
    elsif (interval = measurement[:Interval])
      [interval[:from], interval[:to]].compact.any? { |bound| measurement_point?(bound, expected, unit) }
    else
      false
    end
  end

  def measurement_point?(point, expected, unit)
    close?(point[:value], expected) && point[:unit] == unit
  end

  def close?(actual, expected)
    actual.is_a?(Numeric) && (actual - expected).abs < TOLERANCE
  end

  # Upstream compares a NaiveDateTime, and reads an Instant through
  # `naive_local()`. Both are the leaf's own wall clock.
  def wall_clock(time)
    [time.year, time.month, time.day, time.hour, time.min, time.sec]
  end

  def leaf(tagged)
    tagged[:Naive] || tagged[:Instant]
  end
end
