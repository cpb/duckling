# wafer-inc-duckling API Surface

Research terrain map for the `duckling` Rust crate (v0.4.0) from
[wafer-inc/duckling](https://github.com/wafer-inc/duckling). This subtree
documents the complete public API as it exists in source, cross-verified
against the actual Rust files.

Source root: `/Users/cpb/projects/duks/wafer-inc-duckling/`

---

## Documents

| File | Description |
|------|-------------|
| [public-functions.md](./public-functions.md) | The two public parse entry points (`parse` and `parse_en`), their full signatures, `Context`/`Options` defaults, crate type, and dependency notes. |
| [types.md](./types.md) | All public types in detail: `Entity`, `DimensionKind` (14 variants), `DimensionValue` (14 variants), `MeasurementValue`, `MeasurementPoint`, `TimeValue`, `TimePoint`, `IntervalEndpoints`, and `Grain` — including Naive vs Instant time semantics and Mermaid diagrams. |
| [locale-system.md](./locale-system.md) | The `Locale`/`Lang`/`Region`/`Context`/`Options` system: 49 `Lang` variants, supported region pairs per language, ranking classifier coverage, and the normalisation rules baked into `Locale::new`. |
