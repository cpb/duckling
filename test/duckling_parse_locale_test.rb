# frozen_string_literal: true

require "test_helper"

# Empirically verified behavior (ruby -e against the compiled extension,
# ext/duckling/src/lib.rs `parse_locale`, and README's "Keyword arguments"
# section) before writing these assertions:
#
#   locale: "en"          -> parses normally, no error
#   locale: "xx"           -> raises ArgumentError: 'unsupported locale: "xx"'
#   locale: omitted entirely -> defaults to "en" silently (no ArgumentError for
#                                a missing keyword — `locale` is an optional kwarg
#                                in the Magnus binding, defaulting to "en")
class DucklingParseLocaleTest < Minitest::Test
  def test_valid_locale_en_parses_tomorrow
    results = Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME)

    refute_empty results, "Expected a non-empty result for 'tomorrow' with locale: \"en\""
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow'"
    point = time_point(time_entity[:value][:Time][:Single][:value])
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_invalid_locale_raises_argument_error
    error = assert_raises(ArgumentError) do
      Duckling.parse("tomorrow", locale: "xx", reference_time: REFERENCE_TIME)
    end
    assert_match(/unsupported locale/i, error.message)
    assert_match(/xx/, error.message)
  end

  def test_locale_with_unsupported_region_raises_argument_error
    error = assert_raises(ArgumentError) do
      Duckling.parse("tomorrow", locale: "en-ZZ", reference_time: REFERENCE_TIME)
    end
    assert_match(/unsupported locale/i, error.message)
    assert_match(/en-ZZ/, error.message)
  end

  def test_omitted_locale_defaults_to_en_without_raising
    results = Duckling.parse("tomorrow", reference_time: REFERENCE_TIME)

    refute_empty results, "Expected omitted locale: to default to \"en\" and parse normally"
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result when locale: is omitted"
    point = time_point(time_entity[:value][:Time][:Single][:value])
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
  end

  def test_valid_region_qualified_locale_parses_normally
    results = Duckling.parse("tomorrow", locale: "en-GB", reference_time: REFERENCE_TIME)

    refute_empty results, "Expected a non-empty result for 'tomorrow' with locale: \"en-GB\""
    time_entity = results.find { |r| r[:dim] == :time }
    refute_nil time_entity, "Expected a :time dimension result for 'tomorrow' with locale: \"en-GB\""
    point = time_point(time_entity[:value][:Time][:Single][:value])
    assert_equal :day, point[:grain]
    assert_equal Time.new(2013, 2, 13, 0, 0, 0, "-02:00"), point[:value]
  end
end
