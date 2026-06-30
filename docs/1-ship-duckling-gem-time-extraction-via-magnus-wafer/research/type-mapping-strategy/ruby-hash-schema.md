# Target Ruby Hash Schema (0.2.0 — Time Entities Only)

This document defines the target shape of the Ruby hashes returned by `Duckling.parse`
for time/date entities in the 0.2.0 release.

## Key Schema Decision: Symbol Keys and Symbol Values

**All hash keys are Ruby Symbols, not Strings.** Symbol values are used for `:dim`,
`:type`, and `:grain`. String values are used for body text, ISO8601 datetimes.

This was settled by the hill tests in PR #2 (`test/duckling_test.rb`), which assert:
```ruby
assert_equal :time,     entity[:dim]
assert_equal :value,    entity[:value][:type]
assert_equal :day,      entity[:value][:grain]
assert_equal :interval, entity[:value][:type]
assert_equal :hour,     entity[:value][:from][:grain]
```

The implication for the Rust bridge: all `h.aset(key, ...)` calls must use `ruby.sym("key")`
rather than `"key"` as the key; dim/type/grain values must also use `ruby.sym(...)`.
See [magnus-type-conversions.md](./magnus-type-conversions.md) for the updated Rust code.

## Design Constraint: pyduckling Compatibility

The pyduckling Python library is the reference implementation for test parity. Its JSON
output shape (string keys) is documented below for reference, but the Ruby gem uses
**symbol keys** to feel idiomatic in Ruby. For test cases drawn from pyduckling, the
value semantics are compatible but the key type differs.

pyduckling JSON for a single time value ("tomorrow" with reference time 2013-02-12T04:30:00-02:00):

```json
{
  "body": "tomorrow",
  "start": 0,
  "end": 8,
  "latent": false,
  "value": {
    "type": "value",
    "value": "2013-02-13T00:00:00.000-02:00",
    "grain": "day",
    "values": [
      {"type": "value", "value": "2013-02-13T00:00:00.000-02:00", "grain": "day"}
    ]
  }
}
```

pyduckling JSON for an interval ("from 3pm to 5pm"):

```json
{
  "body": "from 3pm to 5pm",
  "start": 0,
  "end": 16,
  "latent": false,
  "value": {
    "type": "interval",
    "from": {"type": "value", "value": "2013-02-12T15:00:00.000-02:00", "grain": "hour"},
    "to":   {"type": "value", "value": "2013-02-12T17:00:00.000-02:00", "grain": "hour"}
  }
}
```

---

## Target Ruby Hash Shape

### Entity (outer wrapper)

```ruby
{
  body:   "tomorrow",   # String  — matched text
  start:  0,            # Integer — byte offset of match start
  end:    8,            # Integer — byte offset of match end
  dim:    :time,        # Symbol  — dimension kind (from entity.value.dim_kind().to_string())
  latent: false,        # Boolean — omitted if nil (Entity.latent is Option<bool>)
  value:  { ... }       # Hash    — see TimeValue shapes below
}
```

Notes:
- All keys are Symbols, not Strings.
- `:dim` is derived from `entity.value.dim_kind()` (e.g. `DimensionKind::Time` → `:time`).
  The `DimensionKind::Display` impl produces lowercase strings matching the hill test values.
- `latent` is `Option<bool>` in Rust. When `None`, omit the key entirely.
  (Consistent with the `#[serde(skip_serializing_if = "Option::is_none")]` attribute.)

### TimeValue::Single — Instant (has timezone offset)

`TimePoint::Instant` carries a `DateTime<FixedOffset>` — an absolute moment with a known
UTC offset. This maps cleanly to a timezone-aware ISO8601 string.

```ruby
{
  type:   :value,
  value:  "2013-02-12T05:30:00-02:00",   # ISO8601 String with UTC offset
  grain:  :minute,                         # Symbol — grain as symbol via grain.as_str()
  values: [
    { type: :value, value: "2013-02-12T05:30:00-02:00", grain: :minute }
  ]
}
```

### TimeValue::Single — Naive (no timezone in source text)

`TimePoint::Naive` carries a `NaiveDateTime` — a wall-clock time with no timezone baked in.
This is the common case for phrases like "tomorrow", "next Monday", "at 3pm".

**Decision (0.2.0): Option N1 — strip timezone, return bare ISO8601**

pyduckling always returns a timezone-aware ISO8601 string, applying the reference timezone
even to wall-clock times. wafer-inc-duckling's `NaiveDateTime` has no timezone. Two options:

**Option N1 (chosen): bare ISO8601, no offset**

```ruby
{
  type:   :value,
  value:  "2013-02-13T00:00:00",   # ISO8601 String without timezone
  grain:  :day,
  values: [
    { type: :value, value: "2013-02-13T00:00:00", grain: :day }
  ]
}
```

Pros: semantically honest — the value really has no timezone. The hill test in PR #2
uses `assert_match(/\A\d{4}-\d{2}-\d{2}/, entity[:value][:value])` — prefix-only, tolerates
missing offset.
Cons: breaks direct equality with pyduckling test cases which always include an offset.

**Option N2: apply reference timezone at serialization time** (deferred to 0.3.0)

Pros: matches pyduckling format exactly.
Cons: requires threading the reference `Context` timezone through to serialization;
the offset is synthetic. Revisit if test parity becomes important.

### TimeValue::Interval

```ruby
{
  type: :interval,
  from: {
    type:  :value,
    value: "2013-02-12T15:00:00-02:00",  # String — bare if Naive
    grain: :hour                           # Symbol
  },
  to: {
    type:  :value,
    value: "2013-02-12T17:00:00-02:00",
    grain: :hour
  }
  # :values array omitted (IntervalEndpoints array; pyduckling omits it too)
}
```

Note: `from` and `to` are `Option<TimePoint>` — either may be nil (open-ended interval).
When nil, omit the key from the hash. The hill test asserts both `:from` and `:to` are
present for "from 3pm to 5pm", and that each has `:type: :value` and `:grain: :hour`.

---

## Grain Symbol Mapping

`Grain::as_str()` returns lowercase strings that must be converted to Ruby Symbols in the
output. The manual mapping calls `grain.as_str()` and wraps the result in `ruby.sym(...)`.

| Variant | `as_str()` | Ruby symbol | pyduckling |
|---------|-----------|-------------|------------|
| `NoGrain` | `"no_grain"` | `:no_grain` | `"nosec"` (diverges — see note) |
| `Second` | `"second"` | `:second` | `"second"` |
| `Minute` | `"minute"` | `:minute` | `"minute"` |
| `Hour` | `"hour"` | `:hour` | `"hour"` |
| `Day` | `"day"` | `:day` | `"day"` |
| `Week` | `"week"` | `:week` | `"week"` |
| `Month` | `"month"` | `:month` | `"month"` |
| `Quarter` | `"quarter"` | `:quarter` | `"quarter"` |
| `Year` | `"year"` | `:year` | `"year"` |

`NoGrain` note: `as_str()` returns `"no_grain"` while the original Haskell duckling
documentation uses `"nosec"`. Use `"no_grain"` for 0.2.0 (clearer semantics); document
the divergence. In practice, `NoGrain` appears only for `now` — verify before shipping
if any real `Time` entities carry `NoGrain`.

---

## Key Differences from pyduckling Schema

| Field | pyduckling | This gem (0.2.0 target) |
|-------|-----------|-------------------------|
| Key type | String (`"body"`, `"grain"`) | Symbol (`:body`, `:grain`) |
| `dim` key | absent on entity | `:dim` Symbol, derived from `dim_kind()` |
| `latent` | always present (`true`/`false`) | omitted when `None` |
| Naive datetime | `"2013-02-13T00:00:00.000-02:00"` (offset applied) | `"2013-02-13T00:00:00"` (no offset) |
| Datetime format | `.000` milliseconds always included | no milliseconds for whole seconds |
| `values` in Interval | not present in pyduckling output | omitted in 0.2.0 |
| Grain | String `"day"` | Symbol `:day` |
| Grain for NoGrain | `"nosec"` | `:no_grain` (from `as_str()`) |
| `type` field | String `"value"` / `"interval"` | Symbol `:value` / `:interval` |
