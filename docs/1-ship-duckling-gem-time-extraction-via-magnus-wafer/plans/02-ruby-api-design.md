# Plan 02: Ruby API Design — `Duckling.parse`

## Decision

### 1. API Signature

```ruby
Duckling.parse(text, locale: "en", dims: ["time"], reference_time: nil, with_latent: false)
```

- `text` — positional String, required.
- `locale:` — BCP-47 tag string; default `"en"`. Split on `-` to produce `Lang` + optional `Region`. Validated at call time; unknown codes raise `ArgumentError`.
- `dims:` — Array of dimension name strings; default `["time"]`. Unknown strings raise `ArgumentError` in 0.2.0 (fail loud rather than silently skip).
- `reference_time:` — Ruby `Integer` (Unix seconds). When `nil`, falls back to `Context::default()` (`Utc::now()` + EN-US locale). **Include in 0.2.0** for testability (see Open Questions).
- `with_latent:` — Boolean; default `false`. Mirrors `Options { with_latent }` in [duckling](https://github.com/wafer-inc/duckling). When `false`, latent/ambiguous entities are excluded (matches `Options::default()`).
- Returns `Array<Hash>` — one hash per entity, with **Symbol keys and Symbol values** for dim/type/grain. See [ruby-hash-schema.md](../research/type-mapping-strategy/ruby-hash-schema.md).

### 2. Type Conversion — Manual Magnus Mapping (Option B)

Do **not** use `serde_magnus`. The verified serde attributes on `DimensionValue`, `TimeValue`, `TimePoint`, and `Grain` produce externally-tagged enum shapes (`{"Time": {"Single": {...}}}`) and PascalCase grain names (`"Day"`) that do not match the target schema. See [serialization-options.md](../research/type-mapping-strategy/serialization-options.md) for the verified analysis.

Use manual `RHash`/`RArray` construction via the Magnus API. Full helper code is in [magnus-type-conversions.md](../research/type-mapping-strategy/magnus-type-conversions.md).

### 3. NaiveDateTime — Option N1 (bare ISO8601, no offset)

`TimePoint::Naive` carries a `chrono::NaiveDateTime` with no timezone. Serialize as `"%Y-%m-%dT%H:%M:%S"` — no offset appended. Semantically honest; pyduckling applies the reference timezone synthetically, which this gem does not do in 0.2.0. Document the divergence in README.

`TimePoint::Instant` carries a `DateTime<FixedOffset>`. Serialize with `.to_rfc3339()` — preserves the exact offset.

---

## Rationale

| Decision | Why |
|----------|-----|
| Keyword args with defaults | Idiomatic Ruby; callers can set only what they need. `reference_time:` enables deterministic tests. |
| Manual Magnus mapping | `serde_magnus` output is wrong (externally-tagged enums, PascalCase grains) without upstream serde-attribute changes out of scope for 0.2.0. Option B is bounded: only `DimensionValue::Time` needs deep handling. |
| NaiveDateTime as bare ISO8601 | `NaiveDateTime` has no `IntoValue` impl in Magnus's chrono feature. Attaching a synthetic offset requires threading `Context` timezone into serialization. N1 avoids the complexity and is semantically correct. |
| Unknown dim/locale → `ArgumentError` | Fail loud. Silently dropping unknown dims produces confusing empty results. |
| `reference_time:` in 0.2.0 | Without it, `Context::default()` uses `Utc::now()`, making assertions on relative expressions ("tomorrow") non-deterministic. |

See [locale-system.md](../research/wafer-inc-duckling-api/locale-system.md) for supported `Lang`/`Region` pairs and [types.md](../research/wafer-inc-duckling-api/types.md) for the full `Entity`/`DimensionValue`/`TimeValue`/`TimePoint` type hierarchy.

---

## Steps

### 1. `ext/duckling/src/lib.rs` — Register module function and implement parse

**Init function:**

```rust
#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Duckling")?;
    module.define_singleton_method("parse", function!(parse, -1))?;
    Ok(())
}
```

**Parse function** (uses `scan_args` for keyword handling):

```rust
fn parse(ruby: &Ruby, args: &[Value]) -> Result<RArray, Error> {
    let args = scan_args::scan_args::<(String,), (), (), (), _, ()>(args)?;
    let kw = scan_args::get_kwargs::<
        _, (),
        (Option<String>, Option<Vec<String>>, Option<i64>, Option<bool>),
        ()
    >(args.keywords, &[], &["locale", "dims", "reference_time", "with_latent"])?;

    let text        = args.required.0;
    let locale_str  = kw.optional.0.unwrap_or_else(|| "en".to_string());
    let dims_strs   = kw.optional.1.unwrap_or_else(|| vec!["time".to_string()]);
    let ref_time_i  = kw.optional.2; // Option<i64> Unix seconds
    let with_latent = kw.optional.3.unwrap_or(false);

    let locale  = parse_locale_str(&locale_str)?;      // -> duckling::Locale
    let dims    = parse_dims(&dims_strs)?;              // -> Vec<DimensionKind>
    let context = build_context(ref_time_i)?;           // -> duckling::Context
    let options = Options { with_latent };

    let entities = duckling::parse(&text, &locale, &dims, &context, &options);

    let out = ruby.ary_new();
    for e in &entities {
        out.push(entity_to_ruby(ruby, e)?)?;
    }
    Ok(out)
}
```

**Locale parsing** — split `"en-GB"` on `-`; match the two-letter lang code to `Lang` via a `match` block; match the optional region code to `Region` similarly; call `Locale::new(lang, region)`. Return `ArgumentError` for unknown codes. `Locale::new` normalises unsupported `(Lang, Region)` pairs silently by setting `region = None`.

**Dim parsing** — match strings to `DimensionKind` variants using their `Display` strings from [types.md](../research/wafer-inc-duckling-api/types.md) (`"time"` → `Time`, `"number"` → `Numeral`, `"amount-of-money"` → `AmountOfMoney`, etc.). Raise `ArgumentError` for unrecognised strings.

**Context construction** — when `reference_time` is `Some(unix_secs)`, construct
`DateTime<FixedOffset>` as:
```rust
fn build_context(ref_time_i: Option<i64>) -> Result<Context, Error> {
    match ref_time_i {
        Some(secs) => {
            let utc = DateTime::from_timestamp(secs, 0)
                .ok_or_else(|| Error::new(magnus::exception::arg_error(), "invalid reference_time"))?;
            Ok(Context::new(utc.fixed_offset(), Locale::default()))
        }
        None => Ok(Context::default()),
    }
}
```
Note: `DateTime::from_timestamp(secs, 0)` produces a UTC `DateTime`, then `.fixed_offset()`
converts it to `FixedOffset` with offset +00:00. This loses the caller's original timezone
offset — a known limitation for 0.2.0. For the hill tests, this does not matter (the test
inputs don't span a date boundary under UTC vs. UTC-2). Revisit in 0.3.0 by accepting a
Ruby `Time` object and extracting `.utc_offset` via Magnus.

**Helper functions** — copy `entity_to_ruby`, `time_value_to_ruby`, `time_point_to_ruby` from [magnus-type-conversions.md](../research/type-mapping-strategy/magnus-type-conversions.md) verbatim. Use `ruby.to_symbol(grain.as_str())` for grain values (Symbol, not String). Use `ruby.to_symbol("body")` etc. for all hash keys. The `:dim` key must be added explicitly:
```rust
let dim_str = entity.value.dim_kind().to_string();
h.aset(ruby.to_symbol("dim"), ruby.to_symbol(&dim_str))?;
```

### 2. `lib/duckling.rb` — No Ruby-level changes needed

The Rust `#[magnus::init]` defines the `Duckling` module and its singleton method. The existing file stays as-is; the native extension is loaded via `require "duckling/duckling"` (added by rb-sys). Remove the placeholder `Error` constant stub to avoid confusion.

### 3. `lib/duckling/version.rb` — Bump to 0.2.0

Change `VERSION = "0.1.0"` to `VERSION = "0.2.0"`.

### 4. `README.md` — Document the API and NaiveDateTime divergence

- Show `Duckling.parse` with `locale:`, `dims:`, and `reference_time:` examples.
- Note that wall-clock expressions ("tomorrow", "next Monday") produce ISO8601 strings **without** a timezone offset, unlike pyduckling which applies the reference timezone to all results.
- Note that `reference_time:` accepts a Unix timestamp integer (e.g. `Time.new(2013,2,12,4,30,0,"-02:00").to_i`).

---

## Open Questions

- **`reference_time:` type**: The plan accepts an `i64` Unix timestamp to avoid Magnus `Time` object parsing complexity. An alternative is to accept a Ruby `Time` and extract `.tv_sec` via Magnus. Integer is simpler for 0.2.0; revisit for ergonomics in 0.3.0.

- **Locale parsing implementation**: No `Lang::from_str` exists in the public API. Use a `match` block on the two-letter code string. This is ~50 match arms but is compile-time checked and zero-cost.

- **`NoGrain` string in output**: `Grain::NoGrain.as_str()` returns `"no_grain"`; pyduckling emits `"nosec"`. Use `"no_grain"` for 0.2.0 (clearer semantics) and document the divergence. Verify whether any real `Time` entities actually carry `NoGrain` before committing.

- **Non-Time dimensions in 0.2.0**: `entity_to_ruby` only handles `DimensionValue::Time`. When caller requests only `dims: ["time"]` (the default), non-Time entities are impossible. If a caller passes other dims explicitly, they get `ArgumentError` from the dim parser — acceptable for 0.2.0.

---

## Verification

After `bundle exec rake compile`:

```ruby
require "duckling"

ref = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i
results = Duckling.parse("tomorrow", locale: "en", reference_time: ref)
results.first[:body]            # => "tomorrow"
results.first[:dim]             # => :time
results.first[:value][:type]    # => :value
results.first[:value][:grain]   # => :day
results.first[:value][:value]   # => "2013-02-13T00:00:00"  (no offset — Naive)

results2 = Duckling.parse("in one hour", locale: "en", reference_time: ref)
results2.first[:value][:value]  # => "2013-02-12T06:30:00+00:00"  (Instant, has offset)
results2.first[:value][:grain]  # => :minute

# Note: reference_time is reconstructed at UTC+0 (see Context construction above).
# The Instant value above uses +00:00 because the reference was passed as a bare i64.
# The hill tests do not check the offset on Instant values, so this passes.
```
