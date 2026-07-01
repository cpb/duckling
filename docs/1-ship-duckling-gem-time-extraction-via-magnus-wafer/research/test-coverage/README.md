# Test Coverage Research

This subtree documents what test cases to port from [duckling](https://github.com/wafer-inc/duckling) and pyduckling into the Ruby minitest suite for the 0.2.0 release.

## Table of Contents

| File | Description |
|------|-------------|
| [Corpus Cases: wafer-inc-duckling English Time Corpus](corpus-cases.md) | Categorized time corpus cases from [`src/corpus/time_en.rs`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/corpus/time_en.rs) and [`tests/time_corpus.rs`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/tests/time_corpus.rs), with reference setup and Rust helper semantics. |
| [Ruby Minitest Test Suite Design](ruby-test-design.md) | Design for the Ruby minitest test suite: helper pattern, test class structure, and coverage targets for 0.2.0. |
| [pyduckling Reference Tests](pyduckling-reference.md) | pyduckling test cases relevant to the Ruby gem, what to port, and what to skip (Haskell-specific infrastructure). |
