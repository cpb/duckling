# Magnus Type Conversions

Magnus 0.9.0 built-in `IntoValue` implementations and manual hash/array construction
APIs, sourced from the local Magnus checkout at `/Users/cpb/projects/duks/magnus/`.

## Built-in IntoValue Implementations

These types implement `IntoValue` automatically — they can be returned from a Magnus
`function!` or passed to `RHash::aset` without additional code:

| Rust type | Ruby type | Source |
|-----------|-----------|--------|
| `&str` | `String` | `src/r_string.rs:1954` |
| `String` | `String` | `src/r_string.rs:1971` |
| `i64` | `Integer` | `src/value.rs:121` |
| `u64` | `Integer` | `src/value.rs:175` |
| `usize` | `Integer` | `src/value.rs:193` |
| `f64` | `Float` | `src/value.rs:211` |
| `bool` | `true`/`false` | `src/value.rs:2220` |
| `Option<T: IntoValue>` | `T` or `nil` | `src/value.rs:2074` |
| `Vec<T: IntoValueFromNative>` | `Array` | `src/r_array.rs:1638` |
| `HashMap<K, V>` | `Hash` | `src/r_hash.rs:972` |
| `BTreeMap<K, V>` | `Hash` | `src/r_hash.rs:993` |
| `RHash` | `Hash` | `src/r_hash.rs:965` |
| `RArray` | `Array` | `src/r_array.rs:1607` |
| `SystemTime` | `Time` | `src/time.rs:323` |

**Important note on `Vec<T>`:** `Vec<T>` only implements `IntoValue` when `T: IntoValueFromNative`.
`IntoValueFromNative` is a safety marker that excludes types containing `Value`. Primitives
and structs of primitives qualify; types built from `RHash`/`RArray` do not. When building
a Vec of Ruby hashes, use `RArray::new()` + `push()` instead.

## chrono Feature: DateTime<FixedOffset> to Ruby Time

Magnus 0.9.0 provides a `chrono` feature that enables automatic conversion of chrono datetime
types to Ruby `Time` objects. Enabled by adding to the extension's Cargo.toml:

```toml
[dependencies]
magnus = { version = "0.9", features = ["chrono"] }
```

With `chrono` enabled, these additional `IntoValue` implementations become available
(source: `src/time.rs`):

| Rust type | Ruby type | Details |
|-----------|-----------|---------|
| `DateTime<chrono::Utc>` | `Time` | UTC time (`src/time.rs:349`) |
| `DateTime<chrono::FixedOffset>` | `Time` | Preserves UTC offset (`src/time.rs:365`) |

`DateTime<FixedOffset>` to Ruby `Time` conversion preserves the UTC offset:

```rust
// src/time.rs:365-378
impl IntoValue for chrono::DateTime<chrono::FixedOffset> {
    fn into_value_with(self, ruby: &Ruby) -> Value {
        let delta = self.signed_duration_since(DateTime::<Utc>::UNIX_EPOCH);
        let ts = Timespec { tv_sec: delta.num_seconds(), tv_nsec: delta.subsec_nanos() as _ };
        let offset = Offset::from_secs(self.timezone().local_minus_utc()).unwrap();
        ruby.time_timespec_new(ts, offset).unwrap().as_value()
    }
}
```

This produces a Ruby `Time` object, not an ISO8601 string. For the hash-based output
format in 0.2.0, the value field should be a String, so use `dt.to_rfc3339()` even for
`Instant` time points.

## Ruby Symbol Keys and Values

All entity hash keys must be Ruby Symbols (`:body`, `:dim`, `:grain`, etc.) and many
values must also be Symbols (`:time`, `:value`, `:interval`, `:day`, etc.). The hill
tests in PR #2 assert this directly.

**Creating symbols in Magnus:**

```rust
// From the Ruby handle — most reliable, interned symbols
let sym = ruby.sym("body");      // → :body
h.aset(ruby.sym("body"), val)?;  // key is :body

// For grain/type/dim values that are also symbols:
h.aset(ruby.sym("grain"), ruby.sym(grain.as_str()))?;      // :grain => :day
h.aset(ruby.sym("type"), ruby.sym("value"))?;              // :type => :value
let dim_str = entity.value.dim_kind().to_string();
h.aset(ruby.sym("dim"), ruby.sym(&dim_str))?;              // :dim => :time
```

`ruby.sym(s: &str)` returns a `Symbol` which implements `IntoValue`, so it works anywhere
a value is accepted. `Symbol` keys are compared by identity (interned), making symbol-keyed
hashes more efficient to look up in Ruby.

**`DimensionKind::Display` for the `:dim` value:**

`DimensionKind` implements `Display`. The string it produces is what `DimensionKind::Time.to_string()` returns:

```
DimensionKind::Time         → "time"         → :time
DimensionKind::Numeral      → "number"        → :number
DimensionKind::AmountOfMoney → "amount-of-money" → :"amount-of-money"
```

For 0.2.0 (Time only), this always produces `"time"` → `:time`. For future dimensions, the
hyphenated names produce symbols like `:"amount-of-money"` which are valid Ruby Symbols but
require quotes when written as literals.

---

## NaiveDateTime: No Automatic Conversion

`chrono::NaiveDateTime` does **not** get an `IntoValue` implementation from the `chrono`
feature. Ruby's `Time` always has a timezone; there is no direct mapping for a naive
datetime. `NaiveDateTime` must be handled manually.

Two practical approaches for `TimePoint::Naive`:

1. **Serialize as ISO8601 String:** Call `.format("%Y-%m-%dT%H:%M:%S").to_string()` and
   pass as a Ruby String. Simple and honest (see [ruby-hash-schema.md](./ruby-hash-schema.md)).

2. **Apply reference offset and convert:** Take the `FixedOffset` from the parse `Context`,
   call `NaiveDateTime::and_local_timezone(&offset).single()`, then convert to
   `DateTime<FixedOffset>` which does have `IntoValue`. Matches pyduckling behavior of
   always returning a timezone-aware string, but requires threading the context into the
   serialization code.

## Manual Hash Construction with Magnus

When not using serde_magnus, Ruby hashes are built with `magnus::RHash`. All keys and
grain/type/dim values must be Ruby Symbols (see Symbol section above).

```rust
use magnus::{Ruby, RHash, RArray, Error, Value};
use duckling::{Entity, DimensionValue, TimeValue, TimePoint};

fn time_point_to_ruby(ruby: &Ruby, tp: &TimePoint) -> Result<Value, Error> {
    let h = ruby.hash_new();
    h.aset(ruby.sym("type"), ruby.sym("value"))?;  // :type => :value
    match tp {
        TimePoint::Naive { value, grain } => {
            h.aset(ruby.sym("value"), value.format("%Y-%m-%dT%H:%M:%S").to_string())?;
            h.aset(ruby.sym("grain"), ruby.sym(grain.as_str()))?;  // :grain => :day etc.
        }
        TimePoint::Instant { value, grain } => {
            h.aset(ruby.sym("value"), value.to_rfc3339())?;
            h.aset(ruby.sym("grain"), ruby.sym(grain.as_str()))?;
        }
    }
    Ok(h.as_value())
}

fn time_value_to_ruby(ruby: &Ruby, tv: &TimeValue) -> Result<Value, Error> {
    let h = ruby.hash_new();
    match tv {
        TimeValue::Single { value, values, .. } => {
            h.aset(ruby.sym("type"), ruby.sym("value"))?;  // :type => :value
            // Flatten primary time point fields into the value hash:
            match value {
                TimePoint::Naive { value: dt, grain } => {
                    h.aset(ruby.sym("value"), dt.format("%Y-%m-%dT%H:%M:%S").to_string())?;
                    h.aset(ruby.sym("grain"), ruby.sym(grain.as_str()))?;
                }
                TimePoint::Instant { value: dt, grain } => {
                    h.aset(ruby.sym("value"), dt.to_rfc3339())?;
                    h.aset(ruby.sym("grain"), ruby.sym(grain.as_str()))?;
                }
            }
            let vals = ruby.ary_new();
            for tp in values {
                vals.push(time_point_to_ruby(ruby, tp)?)?;
            }
            h.aset(ruby.sym("values"), vals)?;
        }
        TimeValue::Interval { from, to, .. } => {
            h.aset(ruby.sym("type"), ruby.sym("interval"))?;  // :type => :interval
            if let Some(tp) = from {
                h.aset(ruby.sym("from"), time_point_to_ruby(ruby, tp)?)?;
            }
            if let Some(tp) = to {
                h.aset(ruby.sym("to"), time_point_to_ruby(ruby, tp)?)?;
            }
        }
    }
    Ok(h.as_value())
}

fn entity_to_ruby(ruby: &Ruby, entity: &Entity) -> Result<Value, Error> {
    let h = ruby.hash_new();
    h.aset(ruby.sym("body"), entity.body.clone())?;
    h.aset(ruby.sym("start"), entity.start)?;
    h.aset(ruby.sym("end"), entity.end)?;
    // :dim derived from DimensionKind::Display — "time" → :time
    let dim_str = entity.value.dim_kind().to_string();
    h.aset(ruby.sym("dim"), ruby.sym(&dim_str))?;
    if let Some(latent) = entity.latent {
        h.aset(ruby.sym("latent"), latent)?;
    }
    if let DimensionValue::Time(ref tv) = entity.value {
        h.aset(ruby.sym("value"), time_value_to_ruby(ruby, tv)?)?;
    }
    Ok(h.as_value())
}
```

## Key Magnus APIs

| API | Purpose |
|-----|---------|
| `ruby.hash_new()` | Create a new empty Ruby Hash (`RHash`) |
| `RHash::aset(key, val)` | Set a key-value pair; key and val must implement `IntoValue` |
| `ruby.ary_new()` | Create a new empty Ruby Array (`RArray`) |
| `RArray::push(val)` | Append a value to a Ruby Array |
| `magnus::function!(f, n)` | Wrap a free Rust function taking `n` Ruby arguments as a Ruby method |
| `magnus::method!(T::m, n)` | Wrap an instance method |

## Magnus Version

This analysis is based on Magnus 0.9.0, the version in `/Users/cpb/projects/duks/magnus/Cargo.toml`.
The `chrono` feature uses chrono 0.4.38 (`chrono = { version = "0.4.38", optional = true }`).
