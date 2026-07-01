# Public Parse Functions

Source: [`src/lib.rs`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/lib.rs)

---

## Crate identity

| Field | Value |
|-------|-------|
| Crate name | `duckling` |
| Version | `0.4.0` |
| Cargo.toml | [`Cargo.toml`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/Cargo.toml) |
| Crate type | `rlib` (library, **not** `cdylib`) |
| License | BSD-3-Clause |
| Repository | https://github.com/wafer-inc/duckling |

The Cargo.toml defines no `[lib]` section, so the crate type defaults to
`rlib`. There are **no** `magnus` or `rb-sys` dependencies in the crate
itself — those belong exclusively to the gem's `ext/` layer.

---

## `parse` — full-control entry point

```rust
pub fn parse(
    text: &str,
    locale: &Locale,
    dims: &[DimensionKind],
    context: &Context,
    options: &Options,
) -> Vec<Entity>
```

Defined in `src/lib.rs` (line 73).

### Parameters

| Parameter | Type | Notes |
|-----------|------|-------|
| `text` | `&str` | Input text to parse. |
| `locale` | `&Locale` | Language + optional region. See [`locale-system.md`](./locale-system.md). |
| `dims` | `&[DimensionKind]` | Which dimensions to extract. Pass `&[]` (empty slice) to extract **all** 14 dimensions. |
| `context` | `&Context` | Reference time and locale for resolving relative expressions. |
| `options` | `&Options` | Controls latent entity inclusion. |

### Return value

`Vec<Entity>` — zero or more non-overlapping parsed entities, ranked by
confidence. Overlapping spans are deduplicated by the ranker before
returning.

### Panic behaviour

In release builds (`#[cfg(not(debug_assertions))]`) the function wraps the
inner parser in `catch_unwind`, logs any panic via `log::error!`, and
returns an empty `Vec` rather than unwinding the caller. In debug builds the
panic propagates normally.

### Example (from source doc)

```rust
use duckling::{parse, Locale, Lang, Context, Options, DimensionKind};

let context = Context::default();
let options = Options::default();
let locale = Locale::new(Lang::EN, None);

let entities = parse(
    "I need 3 degrees celsius",
    &locale,
    &[DimensionKind::Temperature],
    &context,
    &options,
);
assert!(!entities.is_empty());
```

---

## `parse_en` — convenience entry point for English

```rust
pub fn parse_en(text: &str, dims: &[DimensionKind]) -> Vec<Entity>
```

Defined in `src/lib.rs` (line 166).

Thin wrapper that hard-codes:
- `locale = Locale::new(Lang::EN, None)` — English, no region
- `context = Context::default()` — `Utc::now()` as reference time, EN-US locale
- `options = Options::default()` — latent entities excluded

### Example (from source doc)

```rust
use duckling::{parse_en, Entity, DimensionKind, DimensionValue};

assert_eq!(
    parse_en("forty-two", &[DimensionKind::Numeral]),
    vec![Entity {
        body: "forty-two".into(),
        start: 0,
        end: 9,
        latent: Some(false),
        value: DimensionValue::Numeral(42.0),
    }]
);
```

---

## `Context` defaults

```rust
impl Default for Context {
    fn default() -> Self {
        Self::new(Utc::now().fixed_offset(), Locale::default())
    }
}
```

`Locale::default()` is `Locale { lang: Lang::EN, region: Some(Region::US) }`.

So `Context::default()` = current UTC time as a fixed-offset datetime, with
EN-US locale.

---

## `Options` defaults

```rust
#[derive(Debug, Clone, Default)]
pub struct Options {
    pub with_latent: bool,
}
```

`Options::default()` = `Options { with_latent: false }`.

With `with_latent: false` (the default), latent/ambiguous entities are
**excluded** from results. Set `with_latent: true` to include them.

```rust
// "morning" is latent — only returned when with_latent is true
let opts = Options { with_latent: true };
let results = parse("morning", &locale, &[DimensionKind::Time], &context, &opts);
// results contains a Time entity with latent = Some(true)

let results = parse("morning", &locale, &[DimensionKind::Time], &context, &Options::default());
// results is empty — latent filtered out
```

---

## Train-only public API

Two additional items are pub-gated behind `#[cfg(feature = "train")]` and
are not part of the normal runtime surface:

- `pub fn train_classifiers(locale, corpus, dims) -> Classifiers`
- `pub use ranking::train::TrainingCorpus`
- `pub use ranking::Classifiers`

The `train` feature is not enabled by the gem; these are irrelevant for
wrapping.
