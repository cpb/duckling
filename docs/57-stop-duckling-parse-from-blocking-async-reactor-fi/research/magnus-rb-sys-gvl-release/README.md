# Releasing the GVL Around `duckling::parse` with Magnus + rb-sys

Issue #57: `Duckling.parse` is a synchronous Rust FFI call that holds Ruby's
GVL (Global VM Lock) for its entire duration. Inside an `Async::Reactor`
(e.g. Falcon), which cooperatively schedules Fibers on a single OS thread,
this stalls every sibling Fiber for the duration of the call —
`test/falcon_fiber_blocking_test.rb` (currently on the
`hill/issue-38/test-drive-the-falcon-fiber-blocking-claim-for-duc/falcon-fiber-blocking`
branch, not yet merged to `main`) empirically demonstrates this: it measures
a ~0.28s max ticker gap, matching the parse call's own duration.

This document researches **how** to fix that with the gem's actual pinned
dependency versions — Magnus 0.8.2 and rb-sys 0.9.128 — verified against the
real vendored/generated source, not just design-doc assumptions. It is a
research document only: no application code (`ext/duckling/src/lib.rs` or
otherwise) is changed as part of this PR. The fix itself is future work.

## Bottom line

Magnus 0.8.2 has **no safe wrapper** for releasing the GVL — no
`Ruby::without_gvl`, no `thread::without_gvl`, nothing. Magnus's own docs
list `rb_thread_call_without_gvl`, `rb_thread_call_without_gvl2`, and
`rb_thread_call_with_gvl` as explicitly unimplemented. The fix has to drop
to the raw `rb-sys` FFI binding directly, using the `magnus::rb_sys` module
that Magnus provides specifically for gaps like this one. That binding is
reachable today with **no `Cargo.toml` changes** — `rb-sys` exposes it
unconditionally, regardless of the `stable-api-compiled-fallback` feature
this gem already depends on.

## Documents in this subtree

| File | Description |
|------|-------------|
| [The Raw `rb_thread_call_without_gvl` FFI Surface](raw-ffi-signature.md) | The verified C signature (cross-checked against Ruby's own header *and* this repo's actual bindgen-generated bindings), `rb_unblock_function_t` semantics, the `magnus::rb_sys` escape-hatch module, and the panic-safety analysis specific to wrapping `duckling::parse`. |
| [Illustrative Sketch: Releasing the GVL Around `duckling::parse`](implementation-sketch.md) | A fenced-code-block sketch (not real `ext/duckling/src/*.rs`) mapping `parse`'s existing before/during/after structure onto a boxed payload, the raw FFI call, and an off-GVL callback. |

## Why this is safe to attempt at all

The current `parse` function in `ext/duckling/src/lib.rs` (285 lines, the
only Rust source file in `ext/duckling/src/`) already has the shape a
GVL-release rewrite needs:

1. **Before**: all Ruby `Value` access — `scan_args`/`get_kwargs` parsing,
   locale/dimension/context validation — happens first, producing fully
   owned Rust values (`String`, `Locale`, `Vec<DimensionKind>`, a
   `chrono`-based `Context`, an `Options` struct).
2. **During**: a single blocking line,
   `let entities = duckling_parse(&text, &locale, &dims, &context, &options);`,
   operates purely on those owned Rust values — it touches no `Value`, no
   Ruby VM state at all.
3. **After**: the Ruby `RArray` return value is built from the resulting
   `Vec<Entity>` (via the `entity_to_ruby` helper), again touching Ruby
   `Value`s only after the blocking call has returned.

Because step 2 has zero Ruby VALUEs alive, it can be moved into an
`extern "C"` callback run without the GVL held — the "before" and "after"
steps stay exactly as they are today, still running with the GVL held.

There is no explicit `catch_unwind` written in `lib.rs` today; Magnus's
`function!(parse, -1)` macro auto-wraps the whole outer function body in
`std::panic::catch_unwind` (confirmed at
[`RubyFunctionCAry::call_handle_error`](https://github.com/matsadler/magnus/blob/0.8.2/src/method.rs#L1402-L1403)).
That automatic wrapping covers only the outer function — it does **not**
reach inside a raw `extern "C"` callback handed to
`rb_thread_call_without_gvl`, since that callback is a separate FFI boundary
the macro-generated wrapper never sees. Any GVL-release implementation must
add its own panic guard around the inner call; see
[raw-ffi-signature.md](raw-ffi-signature.md) for exactly how, including a
correction to a naive first pass at that guard.

## Open follow-ups

These are flagged here rather than left as unresolved prose, per this PR's
research conventions — each should become a filed GitHub issue before or
during implementation, not resolved silently inside this docs-only PR:

- **No cancellation hook (`ubf`) in the sketch.** The illustrative sketch in
  [implementation-sketch.md](implementation-sketch.md) passes `None` for
  `rb_thread_call_without_gvl`'s `ubf` parameter, meaning `Thread#raise` /
  `Thread#kill` against the calling thread (e.g. a request timeout) cannot
  interrupt an in-flight `duckling::parse` call — it will run to completion
  regardless. Given parse calls are expected to be short (~500µs–3ms per the
  [FFI Binding Risks — Hypotheses and Test Results](https://github.com/cpb/duckling/wiki/research-ffi-risks)
  wiki page's Risk 2 measurements), this is likely an acceptable tradeoff,
  but it should be an explicit, filed decision rather than an implicit one.
  That same wiki page is also the origin of the "Magnus has no high-level
  GVL release API" finding this document builds on — it referred to it
  against "Magnus 0.9," which (per this repo's own established finding) was
  never published to crates.io; the actual pinned, published version this
  document verifies against is 0.8.2.
- **Benchmarking whether releasing the GVL is worth it at all.** Ruby's own
  header doc warns that releasing and reacquiring the GVL are "expensive
  operations" and for a short-running `func` it "might be faster to just
  call `func` with blocking everything else" — recommending benchmarking
  before committing to this approach. Given `duckling::parse` calls are
  short (~3ms), this should be measured (e.g. via the existing
  `docs/benchmarks/` harness) rather than assumed.
- **Ruby-version-specific ABI drift.** The exact generated Rust signature
  for `rb_thread_call_without_gvl` was verified against this gem's actual
  `rb-sys`-generated bindings for Ruby 3.3.6 (see
  [raw-ffi-signature.md](raw-ffi-signature.md)); it should be spot-checked
  against the other Ruby versions in CI's test matrix if/when this lands,
  though the underlying C signature has been stable across modern Ruby 3.x.
