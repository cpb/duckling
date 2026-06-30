# Type Mapping Strategy

Research into converting wafer-inc-duckling's Rust types to Ruby values via Magnus.

## Documents

- [serialization-options.md](./serialization-options.md) — Compares the three conversion approaches (serde_magnus, manual Magnus mapping, JSON round-trip) with verified serde attribute analysis and a recommendation.
- [ruby-hash-schema.md](./ruby-hash-schema.md) — Defines the target Ruby Hash shape for time entities in the 0.2.0 release, documenting the pyduckling compatibility target and the open NaiveDateTime timezone question.
- [magnus-type-conversions.md](./magnus-type-conversions.md) — Documents Magnus 0.9.0's built-in Rust-to-Ruby type conversions, the chrono feature gate, and example Rust code for manually building the time entity hash.
