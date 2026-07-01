# Type Mapping Strategy

Research into converting [duckling](https://github.com/wafer-inc/duckling)'s Rust types to Ruby values via Magnus.

**Note (PR #3 review):** This subtree's recommendation (manual Magnus hash mapping,
Option B in serialization-options.md) is what shipped for 0.2.0, but it's anchored in
matching pyduckling's Hash-based decisions. A reviewer flagged a preferred future
direction away from Hash primacy — symbol-keyed `serde_magnus` output consumed by
Ruby pattern-matching factories that build `Data` value objects instead. Tracked as
[issue #32](https://github.com/cpb/duckling/issues/32) (API shape) and
[issue #33](https://github.com/cpb/duckling/issues/33) (naive-time/timezone handling,
ActiveSupport-style, for v0.3.0). See "Option D" in
[serialization-options.md](./serialization-options.md) for the write-up.

## Documents

| File | Description |
|------|-------------|
| [Serialization Options: Rust to Ruby](./serialization-options.md) | Compares the three conversion approaches (serde_magnus, manual Magnus mapping, JSON round-trip) with verified serde attribute analysis and a recommendation. |
| [Target Ruby Hash Schema (0.2.0 — Time Entities Only)](./ruby-hash-schema.md) | Defines the target Ruby Hash shape for time entities in the 0.2.0 release, documenting the pyduckling compatibility target and the open NaiveDateTime timezone question. |
| [Magnus Type Conversions](./magnus-type-conversions.md) | Documents Magnus 0.9.0's built-in Rust-to-Ruby type conversions, the chrono feature gate, and example Rust code for manually building the time entity hash. |
