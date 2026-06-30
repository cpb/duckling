# Serialization Options: Rust to Ruby

Three approaches for converting `Vec<Entity>` from wafer-inc-duckling into a Ruby Array of Hashes.

## Verified Serde Attribute Analysis

Before evaluating options, the actual serde attributes on the relevant types in
`wafer-inc-duckling/src/types.rs` and `dimensions/time_grain/mod.rs` must be known. Here
is what the source shows:

**`Entity`** (`#[derive(serde::Serialize)]`, no container attributes):
- Field-level: `#[serde(skip_serializing_if = "Option::is_none")]` on `latent`
- Struct fields serialize with their Rust names: `body`, `start`, `end`, `value`, `latent`

**`DimensionValue`** (`#[derive(serde::Serialize)]`, no container attributes):
- No `#[serde(tag = ...)]`, no `#[serde(rename_all = ...)]`
- Default serde representation for enums with data: externally tagged
- `DimensionValue::Time(tv)` serializes as `{"Time": <tv>}`, not `{"type": "time", ...}`

**`TimeValue`** (`#[derive(serde::Serialize)]`, no container attributes):
- Field-level attributes only: `#[serde(skip_serializing_if = "Option::is_none", rename = "holidayBeta")]` on `holiday`
- No `#[serde(tag = "type")]` container attribute
- `TimeValue::Single { ... }` serializes as `{"Single": {"value": ..., "values": [...]}}`
- `TimeValue::Interval { ... }` serializes as `{"Interval": {"from": ..., "to": ..., "values": [...]}}`

**`TimePoint`** (`#[derive(serde::Serialize)]`, no container attributes):
- No container attributes
- `TimePoint::Naive { value, grain }` serializes as `{"Naive": {"value": "2013-02-13T00:00:00", "grain": "Naive"}}`
- `TimePoint::Instant { value, grain }` serializes as `{"Instant": {"value": "2013-02-12T04:30:00-02:00", "grain": "Minute"}}`

**`Grain`** (`#[derive(serde::Serialize)]`, no container attributes):
- Unit enum variants serialize as their Rust name (PascalCase): `"Day"`, `"Hour"`, `"Minute"`, etc.
- `Grain::NoGrain` serializes as `"NoGrain"` — not `"no_grain"` as returned by `as_str()`
- Critically: does NOT match pyduckling's lowercase grain strings (`"day"`, `"hour"`, etc.)

**`IntervalEndpoints`** (`#[derive(serde::Serialize)]`):
- No container attributes; struct fields `from` and `to` serialize directly

**`MeasurementValue`** (`#[derive(serde::Serialize)]`):
- No container attributes; externally tagged format

### What serde_magnus would actually produce for a time entity

Given the above, `serde_magnus::serialize(&entity)` on a Time entity for "tomorrow" would
produce this Ruby hash:

```ruby
{
  "body" => "tomorrow",
  "start" => 0,
  "end" => 8,
  "value" => {
    "Time" => {               # <-- externally-tagged DimensionValue::Time
      "Single" => {           # <-- externally-tagged TimeValue::Single
        "value" => {
          "Naive" => {        # <-- externally-tagged TimePoint::Naive
            "value" => "2013-02-13T00:00:00",
            "grain" => "Day"  # <-- PascalCase, not "day"
          }
        },
        "values" => [
          {"Naive" => {"value" => "2013-02-13T00:00:00", "grain" => "Day"}}
        ]
      }
    }
  }
  # latent omitted because skip_serializing_if = "Option::is_none"
}
```

This does **not** match the pyduckling format. The mismatches are:
1. `"Time"` key wrapping `DimensionValue` (pyduckling: flat `"value"` key on Entity)
2. `"Single"`/`"Interval"` keys wrapping `TimeValue` (pyduckling: `"type": "value"/"interval"`)
3. `"Naive"`/`"Instant"` keys wrapping `TimePoint` (pyduckling: flat object with `"type"` field)
4. Grain serialized as `"Day"` not `"day"`

---

## Option A: serde_magnus

Use the `serde_magnus` crate (by OneSignal) to convert any `serde::Serialize` type directly
to a Magnus `Value`. `serde_magnus::serialize(&entity)` returns a `magnus::Value` representing
the complete Ruby object graph.

**Cargo.toml addition:**
```toml
[dependencies]
serde_magnus = "0.8"
```

**Usage:**
```rust
fn parse_time(ruby: &Ruby, text: String, ...) -> Result<Value, Error> {
    let entities = duckling::parse_en(&text, &[DimensionKind::Time]);
    serde_magnus::serialize(&entities).map_err(|e| /* convert error */)
}
```

**Pros:**
- Minimal Rust code — two lines to convert `Vec<Entity>` to a Ruby Array
- All public types already implement `serde::Serialize`
- No need to enumerate variants manually

**Cons:**
- As verified above, the output shape does NOT match pyduckling. All enum types use
  externally-tagged format; Grain uses PascalCase variant names
- Fixing the shape requires adding serde container attributes to wafer-inc-duckling types
  (`#[serde(tag = "type", rename_all = "lowercase")]` on DimensionValue, TimeValue,
  TimePoint; `#[serde(rename_all = "lowercase")]` on Grain)
- Those changes belong in wafer-inc-duckling, not this gem — either upstream them as a PR
  or fork the crate; neither is trivial for 0.2.0

**When to use:** Only if the shape mismatch is acceptable (tests that don't cross-validate
against pyduckling format), or if the serde attributes are added upstream.

---

## Option B: Manual Magnus Mapping

Construct Ruby hashes field-by-field using `magnus::RHash`, `magnus::RArray`, and
`magnus::Value` primitives directly in Rust. The extension controls the exact key names
and structure.

**Pros:**
- Full control over Ruby hash shape — can match pyduckling exactly
- For 0.2.0 scope (Time only), only one `DimensionValue` variant needs deep handling
- No additional crate dependency
- Makes NaiveDateTime representation explicit (see [ruby-hash-schema.md](./ruby-hash-schema.md))

**Cons:**
- More Rust code: must implement a match arm for every `DimensionValue` variant (or at
  minimum the Time variant and a fallthrough)
- Ongoing maintenance cost when wafer-inc-duckling adds new variants

See [magnus-type-conversions.md](./magnus-type-conversions.md) for example Rust code.

**When to use:** Recommended for 0.2.0. Gives pyduckling format compatibility and makes
the NaiveDateTime/Instant distinction explicit.

---

## Option C: JSON Round-Trip

Serialize entities to a JSON string with `serde_json`, return the string to Ruby, let Ruby
parse it with `JSON.parse`.

**Cargo.toml addition:**
```toml
[dependencies]
serde_json = "1"  # already a transitive dep of wafer-inc-duckling
```

**Pros:**
- Simplest Rust code: `serde_json::to_string(&entities).unwrap()`
- No Magnus complexity beyond returning a String

**Cons:**
- Returns a `String`, not a `Hash` — caller must `require "json"` and call `JSON.parse`
- Adds unnecessary serialization + deserialization round-trip (native bridge benefit lost)
- Output has the same enum shape problems as Option A (externally-tagged, PascalCase grains)
- Not a production pattern for a native extension

**When to use:** Only as a debugging tool or rapid prototype to inspect what serde produces.

---

## Recommendation

**Use Option B (Manual Magnus Mapping) for 0.2.0.**

Rationale:
1. The verified serde attributes confirm that Option A (serde_magnus) produces the wrong
   shape without changes to wafer-inc-duckling that are out of scope for 0.2.0.
2. Manual mapping for 0.2.0 is bounded in scope: only `DimensionValue::Time` needs deep
   handling; other variants can return an opaque hash or be omitted.
3. Manual mapping makes the NaiveDateTime representation a first-class decision rather than
   a side effect of serde's chrono integration.
4. Option B keeps the native bridge benefit (no JSON parsing in Ruby) and is idiomatic for
   Magnus extensions.

Option A becomes practical in a later release if wafer-inc-duckling adds appropriate serde
container attributes. At that point, serde_magnus can replace the manual mapping with much
less code.
