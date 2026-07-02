# Duckling Crate Thread-Safety

Research terrain map answering the precondition question for issue #57: is
the wrapped [duckling](https://github.com/wafer-inc/duckling) Rust crate's
`parse` entrypoint safe to call **concurrently from multiple OS threads**?
That's the practical effect of the eventual fix (out of scope for this
docs-only PR) — releasing the GVL around the call into `duckling::parse` in
`ext/duckling/src/lib.rs` lets other Ruby threads/Fibers run Ruby code (and
potentially call back into `Duckling.parse` themselves) while the release is
held elsewhere.

Source examined: [duckling](https://github.com/wafer-inc/duckling)
at commit [`c96b068`](https://github.com/wafer-inc/duckling/tree/c96b0681ab9a097712b20fe838786a2c65efc537),
which is the tip of the repo's only branch (`main`) and whose `Cargo.toml`
reads `version = "0.4.0"` — an exact match for the `duckling = "0.4"` /
`duckling 0.4.0` dependency pinned in this gem's `ext/duckling/Cargo.toml` /
`Cargo.lock`. The crate has no `v*.*.*` git tags (`git ls-remote --tags`
returns nothing), so permalinks below pin to this commit SHA rather than a
tag. The published crates.io source tree for `duckling 0.4.0` was diffed
file-for-file against this commit for every file cited below and is
byte-identical, confirming the SHA is the right anchor.

## Conclusion

**Yes — `duckling::parse` is safe to call concurrently from multiple threads**,
with a precisely bounded scope:

- **No unsynchronized global mutable state exists anywhere in the crate.**
  Every piece of process-wide mutable state is one of three `Mutex`- or
  `OnceLock`-guarded caches (see
  [Global Mutable State Audit](./global-state-audit.md)), each of which
  holds its lock only for a cache lookup/insert, never across a full parse.
  Concurrent calls can race on populating a cache entry (worst case: the
  same regex set, rule set, or classifier gets built twice) but can never
  observe a torn/partial write or deadlock against each other.
- **Every type that crosses thread boundaries is `Send + Sync` by
  construction** — plain data (`Context`, `Options`, `Locale`, `Entity`) or
  explicit `Send + Sync` trait-object bounds (`Predicate`, `Production`).
  Nothing reachable from the public API carries interior mutability
  (`Rc`/`RefCell`/`Cell`) or thread-affinity.
- **Nothing escapes a single call.** The only non-`Send` type in the crate
  (`Rc<Node>`, used internally by the parse engine's `Stash`) is created
  fresh inside `parse_string` on every call and dropped at the end of that
  call; it is never stored in a static, never returned from `parse`, and
  never shared between threads.
- **Scope of this claim**: "safe" here means data-race-free / memory-safe
  concurrent calls with no shared mutable state escaping across calls —
  it does **not** mean panic-safe by default. See
  [Panic Safety and catch_unwind](./panic-safety.md) for the release-vs-debug
  distinction that matters for the GVL-release fix itself.

In short: nothing found in this audit blocks releasing the GVL around
`duckling::parse` on thread-safety grounds. The remaining precondition is
panic handling at the FFI boundary, which is a property of the *wrapper*
extension the eventual fix will write, not of this crate — see
[Panic Safety and catch_unwind](./panic-safety.md).

## Documents

| Document | Description |
|---|---|
| [Global Mutable State Audit](./global-state-audit.md) | Every `static`/`Mutex`/`OnceLock` in the crate (three caches total — two already known, one newly found: a per-locale ranking-classifier cache), what they guard, and why brief-lock cache access can't deadlock or corrupt state under concurrent calls. Also covers `Send`/`Sync` verification of every type that crosses the public API boundary, and confirms the crate's only `Rc` usage stays local to a single call. |
| [Panic Safety and catch_unwind](./panic-safety.md) | The crate's two-layer `catch_unwind` (whole-parse in `lib.rs`, per-rule-production in `engine.rs`), why both are compiled out entirely under `debug_assertions` (this repo's local dev-profile default), and why the eventual GVL-release fix cannot rely on either — it needs its own `catch_unwind` around the FFI callback regardless of build profile. Also notes the crate's built-in `ParseLimits`/`Budget` work caps as context for how bad a single slow/adversarial parse can get. |

## Open follow-ups

- The three internal caches (regex-set cache, rule cache, ranking-classifier
  cache) are all keyed/scoped in ways that make redundant rebuilds under a
  race merely wasteful, not unsound — but this hasn't been empirically
  stress-tested (e.g. hammering `Duckling.parse` from many Ruby threads
  simultaneously once the GVL-release fix lands) to confirm there's no
  practical contention hot spot. Worth a follow-up load test once issue #57's
  code change exists, not blocking this research.
- This document audits the `duckling` crate itself. It does not audit
  Magnus's or `rb-sys`'s guarantees about calling back into Ruby (e.g. via
  `Ruby::get_inner`/callbacks) from a non-GVL-holding thread — that's a
  property of the wrapper code the eventual fix will write, tracked under
  issue #57 itself rather than this crate-focused research doc.
