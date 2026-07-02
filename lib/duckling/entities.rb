# frozen_string_literal: true

module Duckling
  # A parsed entity extracted from text. `dim` is derived from which pattern
  # arm matched the raw `value:` payload from `Duckling::Native.parse` (the
  # wrapped duckling crate's `Entity` struct has no `dim` field of its own —
  # `dim_kind()` is a Rust-side convenience method, not serialized data).
  Entity = Data.define(:body, :start, :end, :dim, :latent, :value)

  module TimePoint
    # An absolute fixed-offset moment (e.g. "now", "in 2 hours", "5pm EST").
    Instant = Data.define(:value, :grain)
    # A wall-clock/calendar time with no timezone assumption (e.g. "5pm", "tomorrow").
    Naive = Data.define(:value, :grain)
  end

  module TimeValue
    # A single time point with up to 3 additional future occurrences.
    Single = Data.define(:value, :values, :holiday)
    # A time interval; `to` is the *exclusive* boundary (see README).
    Interval = Data.define(:from, :to, :values, :holiday)
  end

  # Builds the Data-object graph (Entity/TimeValue/TimePoint) from the raw,
  # symbol-keyed, externally-tagged Hash `Duckling::Native.parse` returns.
  # See docs/issue-32-serde-magnus-comparison.md for how this shape was
  # chosen (issue #32).
  module Entities
    # Grain::as_str() parity table, from the wrapped duckling crate. A naive
    # `.downcase.to_sym` on serde's bare "NoGrain" string gives :nograin, not
    # the correct :no_grain.
    GRAIN_SYMBOLS = {
      "NoGrain" => :no_grain, "Second" => :second, "Minute" => :minute,
      "Hour" => :hour, "Day" => :day, "Week" => :week, "Month" => :month,
      "Quarter" => :quarter, "Year" => :year
    }.freeze

    # DimensionKind::Display vocabulary, keyed by the PascalCase serde tag
    # name. Only Numeral is a real mismatch (tags "Numeral", displays
    # "number"); everything else matches a hyphenated-downcase rule.
    DIM_SYMBOLS = {
      "Numeral" => :number, "Ordinal" => :ordinal, "Temperature" => :temperature,
      "Distance" => :distance, "Volume" => :volume, "Quantity" => :quantity,
      "AmountOfMoney" => :"amount-of-money", "Email" => :email,
      "PhoneNumber" => :"phone-number", "Url" => :url,
      "CreditCardNumber" => :"credit-card-number", "TimeGrain" => :"time-grain",
      "Duration" => :duration, "Time" => :time
    }.freeze

    module_function

    def build(hash)
      case hash
      in {body:, start:, end: end_pos, value:, **rest}
        dim, value = dimension_value(value)
        Entity.new(body:, start:, end: end_pos, dim:, latent: rest.fetch(:latent, false), value:)
      end
    end

    # Only Time gets a dedicated Data-object shape today. Every other
    # DimensionValue variant is externally tagged as a single-key {Tag:
    # payload} Hash regardless of its Rust shape (newtype, struct, or plain
    # scalar), so a generic single-key extraction handles all of them
    # uniformly without per-dim Rust or Ruby code.
    def dimension_value(tagged)
      case tagged
      in {Time: tv}
        [:time, time_value(tv)]
      else
        tag, payload = tagged.first
        [DIM_SYMBOLS.fetch(tag.to_s) { tag.to_s.downcase.to_sym }, payload]
      end
    end

    def time_value(tagged)
      case tagged
      in {Single: {value:, values:, **rest}}
        TimeValue::Single.new(value: time_point(value), values: values.map { time_point(_1) },
          holiday: rest[:holidayBeta])
      in {Interval: {from:, to:, values:, **rest}}
        TimeValue::Interval.new(
          from: from && time_point(from), to: to && time_point(to),
          values: values.map { |e| interval_endpoints(e) },
          holiday: rest[:holidayBeta]
        )
      end
    end

    def interval_endpoints(tagged)
      case tagged
      in {from:, to:}
        [from && time_point(from), to && time_point(to)]
      end
    end

    def time_point(tagged)
      case tagged
      in {Naive: {value:, grain:}}
        TimePoint::Naive.new(value:, grain: grain_symbol(grain))
      in {Instant: {value:, grain:}}
        TimePoint::Instant.new(value:, grain: grain_symbol(grain))
      end
    end

    def grain_symbol(raw) = GRAIN_SYMBOLS.fetch(raw) { raw.downcase.to_sym }
  end
end
