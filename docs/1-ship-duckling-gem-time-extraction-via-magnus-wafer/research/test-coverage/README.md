# Test Coverage Research

This subtree documents what test cases to port from wafer-inc-duckling and pyduckling into the Ruby minitest suite for the 0.2.0 release.

## Table of Contents

- [corpus-cases.md](corpus-cases.md) — Categorized time corpus cases from `wafer-inc-duckling/src/corpus/time_en.rs` and `tests/time_corpus.rs`, with reference setup and Rust helper semantics.
- [ruby-test-design.md](ruby-test-design.md) — Design for the Ruby minitest test suite: helper pattern, test class structure, and coverage targets for 0.2.0.
- [pyduckling-reference.md](pyduckling-reference.md) — pyduckling test cases relevant to the Ruby gem, what to port, and what to skip (Haskell-specific infrastructure).
