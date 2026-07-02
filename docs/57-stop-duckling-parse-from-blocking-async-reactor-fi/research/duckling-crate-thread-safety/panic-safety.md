# Panic Safety and catch_unwind

Thread-safety (no data races, no unsound sharing — see
[Global Mutable State Audit](./global-state-audit.md)) is a necessary but
not sufficient precondition for releasing the GVL around a call into
[duckling](https://github.com/wafer-inc/duckling). The other precondition
is panic handling: a raw `extern "C"` callback given to
`rb_thread_call_without_gvl` (the mechanism the eventual fix will use) must
never let a Rust panic unwind across that FFI boundary — doing so is
undefined behavior. This document establishes exactly what panic-catching
the wrapped crate does and does not provide, at commit
[`c96b068`](https://github.com/wafer-inc/duckling/tree/c96b0681ab9a097712b20fe838786a2c65efc537).

## The crate's two-layer catch_unwind

### Layer 1: whole-parse, in `lib.rs`

```rust
pub fn parse(
    text: &str,
    locale: &Locale,
    dims: &[DimensionKind],
    context: &Context,
    options: &Options,
) -> Vec<Entity> {
    #[cfg(debug_assertions)]
    {
        parse_inner(text, locale, dims, context, options)
    }

    #[cfg(not(debug_assertions))]
    {
        match catch_unwind(AssertUnwindSafe(|| {
            parse_inner(text, locale, dims, context, options)
        })) {
            Ok(entities) => entities,
            Err(payload) => {
                log::error!(
                    "duckling::parse panicked: {}",
                    panic_payload_message(&payload)
                );
                Vec::new()
            }
        }
    }
}
```
— [`lib.rs#L73-L100`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/lib.rs#L73-L100),
with the payload-message helper at
[`lib.rs#L146-L154`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/lib.rs#L146-L154).

Under `#[cfg(not(debug_assertions))]` (i.e. **release builds only**), any
panic anywhere inside `parse_inner` — regex compilation, node composition,
resolution, ranking — is caught, logged via the `log` crate, and converted
into an empty `Vec<Entity>` instead of propagating.

### Layer 2: per-rule-production, in `engine.rs`

```rust
fn safe_production(rule: &Rule, nodes: &[&Node]) -> Option<TokenData> {
    #[cfg(debug_assertions)]
    {
        (rule.production)(nodes)
    }

    #[cfg(not(debug_assertions))]
    {
        catch_unwind(AssertUnwindSafe(|| (rule.production)(nodes)))
            .ok()
            .flatten()
    }
}
```
— [`engine.rs#L286-L297`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/engine.rs#L286-L297),
called from five call sites within `engine.rs` (lines 336, 435, 465, 494,
551) each time a rule's `production` closure is invoked against candidate
nodes.

This is a finer-grained safety net: if a single rule's production closure
panics (e.g. on a malformed date arithmetic edge case), only that rule's
contribution to the current parse is dropped (`None`), rather than the
panic having to unwind all the way out to the `catch_unwind` in `parse`
(which it would anyway also survive, in a release build — this is a
resilience/blast-radius design, not a second independent barrier the
wrapper can rely on separately).

## The critical nuance: both layers are release-build only

Both `#[cfg(not(debug_assertions))]` gates mean **neither `catch_unwind`
compiles in at all under a debug build** — `cfg(debug_assertions)` is true
whenever Cargo's `dev` profile (the default for `cargo build` without
`--release`) is used, false only for the `release` profile. In a debug
build, `parse` just calls `parse_inner` directly with no unwind boundary,
and `safe_production` just calls `(rule.production)(nodes)` directly.

This matters concretely for this gem's own build configuration, not just as
a hypothetical: this repo's `.env.local.example` sets
`RB_SYS_CARGO_PROFILE=dev`, and `bin/setup` copies it to `.env.local` (see
`AGENTS.md`'s "Build and test commands" section) — meaning **local
development builds of this gem, by default, build the wrapped
[duckling](https://github.com/wafer-inc/duckling) crate in debug mode**,
where a panic inside `duckling::parse` is a real, uncaught Rust unwind.
Only CI (`bundle exec rake` with no `.env.local` present) and `rake release`
build the crate's `release` profile, where the crate's own two-layer
`catch_unwind` is active.

## Why this means the wrapper needs its own catch_unwind regardless

Because the crate's internal panic-catching is conditionally compiled out
in debug builds — and because the wrapper's `Cargo.toml` doesn't control
this: `debug_assertions` is derived from the *crate's own* compilation
profile when the wrapped `duckling` dependency itself gets built, which
Cargo unifies across the workspace/build graph with whatever profile the
top-level build uses — the eventual GVL-release fix in
`ext/duckling/src/lib.rs` **cannot assume `duckling::parse` will never
panic across the boundary it controls**, in either build profile:

- In a `dev`-profile build (this repo's local default), the wrapped
  crate's `catch_unwind` doesn't exist at all — any panic inside
  `duckling::parse` unwinds straight out of that function call.
- Even in a `release`-profile build, the crate's own `catch_unwind` only
  covers `parse_inner`'s body and each rule's `production` closure; it
  isn't a guarantee scoped to "this specific FFI call can never panic" —
  it's a best-effort internal resilience mechanism, not a documented
  external contract (the crate's `README.md` makes no such promise — see
  below).

Since unwinding a Rust panic across an `extern "C"` boundary invoked via
`rb_thread_call_without_gvl` is undefined behavior (Rust panics are not
FFI-safe by default; `-Cpanic=abort` would turn them into a process abort
instead, which Ruby doesn't build with), **the wrapper's own
`without_gvl` callback needs to wrap its call to `duckling::parse` in its
own `catch_unwind`, unconditionally, regardless of Cargo profile.** This is
a separate, independent concern from "release vs. debug changes what the
*wrapped* crate itself catches" — the wrapper cannot delegate this
responsibility to the dependency at all, in any profile, because the
dependency's guarantee (where it exists) is internal and non-contractual,
not something the wrapper can rely on across a semver-compatible version
bump either.

## Context: built-in work limits bound worst-case single-call cost

Separately from panic safety, the crate already bounds how much CPU a
single `parse()` call can consume, via `ParseLimits`
([`engine.rs#L27-L44`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/engine.rs#L27-L44) —
caps on regex matches per rule, rule results, new nodes per iteration,
total nodes, and iterations) and `Budget`
(`DEFAULT_WORK_BUDGET = 250_000` at
[`dimensions/time/series.rs#L31`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/dimensions/time/series.rs#L31),
threaded explicitly through `resolve` per the comment in `parse_inner`
rather than stored in any thread-local). This is relevant framing for *why*
releasing the GVL is worth doing at all: a single slow/adversarial input
can't blow up unboundedly, but it can still legitimately take long enough
(bounded, not unbounded) to be worth not blocking sibling Fibers/threads
for. It has no bearing on the panic-safety conclusion above — the caps
bound iteration/allocation counts, not whether any given code path can
panic (e.g. on an arithmetic overflow the `#[warn(clippy::arithmetic_side_effects)]`
lint at [`lib.rs#L3`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/lib.rs#L3)
tries to flag at compile time but doesn't eliminate — it's a `warn`, not a
`deny`).

## Conclusion for this document

The wrapped crate's internal `catch_unwind` layers are a real but
**conditional, internal, non-contractual** resilience mechanism — active
only in release builds, absent in this repo's own local dev-profile
default. The eventual GVL-release fix in `ext/duckling/src/lib.rs` must
install its own `catch_unwind` around the `without_gvl` callback,
unconditionally, and must not treat the wrapped crate's internal handling
as a substitute.
