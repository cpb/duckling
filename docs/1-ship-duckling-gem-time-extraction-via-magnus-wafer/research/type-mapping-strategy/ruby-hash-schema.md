# Target Ruby Hash Schema (0.2.0 — Time Entities Only)

This document defines the target shape of the Ruby hashes returned by `Duckling.parse`
for time/date entities in the 0.2.0 release.

## Design Constraint: pyduckling Compatibility

The pyduckling Python library is the reference implementation for test parity. Its JSON
output shape is documented below. For test cases drawn from pyduckling, the Ruby gem must
produce structurally equivalent hashes.

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
  "body"   => "tomorrow",   # String — matched text
  "start"  => 0,            # Integer — byte offset of match start
  "end"    => 8,            # Integer — byte offset of match end
  "latent" => false,        # Boolean — omitted if nil (Entity.latent is Option<bool>)
  "value"  => { ... }       # Hash — see TimeValue shapes below
}
```

Note: `latent` is `Option<bool>` in Rust. When `None`, the key should be omitted
(consistent with the `#[serde(skip_serializing_if = "Option::is_none")]` attribute on Entity).

### TimeValue::Single — Instant (has timezone offset)

`TimePoint::Instant` carries a `DateTime<FixedOffset>` — an absolute moment with a known
UTC offset. This maps cleanly to a timezone-aware ISO8601 string.

```ruby
{
  "type"   => "value",
  "value"  => "2013-02-12T05:30:00-02:00",   # ISO8601 with UTC offset
  "grain"  => "minute",                        # lowercase string (see Grain note below)
  "values" => [
    {"type" => "value", "value" => "2013-02-12T05:30:00-02:00", "grain" => "minute"}
  ]
}
```

### TimeValue::Single — Naive (no timezone in source text)

`TimePoint::Naive` carries a `NaiveDateTime` — a wall-clock time with no timezone baked in.
This is the common case for phrases like "tomorrow", "next Monday", "at 3pm".

**Open question: should Naive datetimes include the reference timezone offset in Ruby output?**

pyduckling always returns a timezone-aware ISO8601 string, applying the reference timezone
even to wall-clock times. wafer-inc-duckling's `NaiveDateTime` has no timezone. Two options:

**Option N1: Strip timezone, return bare ISO8601**

```ruby
{
  "type"   => "value",
  "value"  => "2013-02-13T00:00:00",   # ISO8601 without timezone
  "grain"  => "day",
  "values" => [
    {"type" => "value", "value" => "2013-02-13T00:00:00", "grain" => "day"}
  ]
}
```

Pros: honest — the value really has no timezone. Callers who know the reference timezone
can apply it themselves.
Cons: breaks parity with pyduckling test cases which always have a timezone offset.

**Option N2: Apply reference timezone at serialization time**

```ruby
{
  "type"   => "value",
  "value"  => "2013-02-13T00:00:00.000-02:00",  # reference TZ applied
  "grain"  => "day",
  "values" => [
    {"type" => "value", "value" => "2013-02-13T00:00:00.000-02:00", "grain" => "day"}
  ]
}
```

Pros: matches pyduckling format exactly; test parity is straightforward.
Cons: requires threading the reference `Context` timezone through to the serialization step;
the offset is synthetic (the original text had no timezone).

**Recommendation for 0.2.0:** Start with Option N1 (no timezone on Naive) to keep the
native extension simple and semantically honest. Accept that test cases drawn from pyduckling
will require tolerance for the missing offset, or will need a separate normalization step.
Revisit if test parity proves difficult. Document the divergence in the gem's README.

### TimeValue::Interval

```ruby
{
  "type" => "interval",
  "from" => {
    "type"  => "value",
    "value" => "2013-02-12T15:00:00-02:00",  # or bare if Naive
    "grain" => "hour"
  },
  "to" => {
    "type"  => "value",
    "value" => "2013-02-12T17:00:00-02:00",
    "grain" => "hour"
  }
  # "values" array omitted for now (IntervalEndpoints array; pyduckling omits it too)
}
```

Note: `from` and `to` are `Option<TimePoint>` — either may be nil (open-ended interval).
When nil, omit the key from the hash.

---

## Grain String Mapping

`Grain` derives `serde::Serialize` but has **no** `rename_all` attribute. Its default serde
output is PascalCase variant names (`"Day"`, `"Hour"`, `"NoGrain"`). This does not match
pyduckling's lowercase strings (`"day"`, `"hour"`, `"no_grain"`).

The manual mapping approach must use `Grain::as_str()` to produce the correct lowercase
strings. `as_str()` returns:

| Variant | `as_str()` | pyduckling |
|---------|-----------|------------|
| `NoGrain` | `"no_grain"` | `"nosec"` (pyduckling uses "nosec" for no-grain) |
| `Second` | `"second"` | `"second"` |
| `Minute` | `"minute"` | `"minute"` |
| `Hour` | `"hour"` | `"hour"` |
| `Day` | `"day"` | `"day"` |
| `Week` | `"week"` | `"week"` |
| `Month` | `"month"` | `"month"` |
| `Quarter` | `"quarter"` | `"quarter"` |
| `Year` | `"year"` | `"year"` |

Open question: `Grain::NoGrain` maps to `as_str() = "no_grain"`, but the original duckling
documentation uses `"nosec"`. Verify what pyduckling actually emits for a NoGrain time point
before finalizing the mapping.

---

## Key Differences from pyduckling Schema

| Field | pyduckling | This gem (0.2.0 target) |
|-------|-----------|-------------------------|
| `latent` | always present (`true`/`false`) | omitted when `None` |
| Naive datetime | `"2013-02-13T00:00:00.000-02:00"` (offset applied) | `"2013-02-13T00:00:00"` (no offset) |
| Datetime format | `.000` milliseconds always included | no milliseconds for whole seconds |
| `values` in Interval | not present in pyduckling output | omitted in 0.2.0 |
| Grain for NoGrain | `"nosec"` | `"no_grain"` (from `as_str()`) |
