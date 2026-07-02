# Plan: GVL-Release Implementation for `Duckling.parse`

Concrete implementation shape for issue #57 ("stop `Duckling.parse` from
blocking the async reactor"), synthesizing this issue's four "how"/"why"
research topics into one decision. This is a plan, not a patch — no
application code (`ext/duckling/`, `lib/`) changes as part of this PR; the
actual rewrite is future work for an implementation PR.

## Source research

| Document | Covers |
|---|---|
| [Releasing the GVL Around `duckling::parse` with Magnus + rb-sys](../research/magnus-rb-sys-gvl-release/README.md) | Rust FFI mechanics: raw `rb_thread_call_without_gvl`, panic-guard placement |
| [Fiber-Scheduler Mechanism Spike](../research/fiber-scheduler-mechanism-spike/README.md) | Empirical proof that GVL-release alone doesn't pass the test; Thread-spawn is also required |
| [Duckling Crate Thread-Safety](../research/duckling-crate-thread-safety/README.md) | Why concurrent calls into the wrapped crate are sound |
| [Concurrency Alternatives Comparison](../research/concurrency-alternatives-comparison/README.md) | Thread-per-call vs. worker-pool dispatch recommendation |
| [Test-and-CI Mechanics for `falcon_fiber_blocking_test.rb`](../research/test-and-ci-mechanics/README.md) | Confirms no CI/CD changes are needed alongside the code fix |

## Decision

Ship the combination the spike actually measured, not the GVL release alone:

1. **In `ext/duckling/src/lib.rs`**: wrap the existing single blocking line
   (`duckling_parse(&text, &locale, &dims, &context, &options)`, current
   `parse` function,
   [lines 28–64](https://github.com/cpb/duckling/blob/35a350acebadb8559b94e9f5b1e5076ca26edb66/ext/duckling/src/lib.rs#L28-L64))
   in a raw `rb_sys::rb_thread_call_without_gvl` call, per the
   [implementation sketch](../research/magnus-rb-sys-gvl-release/implementation-sketch.md):
   a boxed `ParsePayload` carries owned inputs in and an owned
   `Result<Vec<Entity>, String>` out across the FFI boundary; an
   `extern "C" fn parse_without_gvl` callback runs the call inside
   `std::panic::catch_unwind`; the outer `parse` reclaims the box, and only
   *after* the GVL is confirmed reacquired does it convert an `Err` into a
   real `magnus::Error` (`ruby.exception_fatal()`-classed) or an `Ok` into
   the `RArray` the AFTER block already builds today.
2. **At the Ruby level**: `Duckling.parse` spawns a genuine background
   `Thread` around the (now GVL-releasing) native call and joins it with
   `.value`, matching the "Approach A+B combined" prototype in
   [`results.md`](../research/fiber-scheduler-mechanism-spike/results.md#approach-ab-combined-rb_thread_call_without_gvl-and-a-spawned-background-thread) —
   the only variant that passed (11/11 runs, Ruby 3.3.6 and 3.4.5).

Neither piece alone is the decision — the spike measured both in isolation
and both failed (see Rationale). Dispatch is **thread-per-call** (a fresh
`Thread.new` per invocation), not a persistent worker pool, per the
[Concurrency Alternatives Comparison](../research/concurrency-alternatives-comparison/README.md#recommendation).

One correction to how this task was framed: the panic guard around the
off-GVL callback should use `std::panic::catch_unwind` directly, storing a
plain `String` panic message in the payload — **not**
`magnus::rb_sys::catch_unwind` inside the callback. The sketch deliberately
avoids that
(see [raw-ffi-signature.md's "subtlety" section](../research/magnus-rb-sys-gvl-release/raw-ffi-signature.md#a-subtlety-worth-getting-right-dont-let-magnusrb_syscatch_unwinds-error-path-do-vm-work-off-gvl)):
`magnus::rb_sys::catch_unwind`'s error path was traced and confirmed to only
touch an immortal `rb_eFatal` global (not unsound here specifically), but a
payload of plain Rust data with zero Magnus/Ruby types is a simpler,
mechanically-checkable invariant, and sidesteps this repo's established
rule against stashing a bare `magnus::Value` (or anything wrapping one,
like `magnus::Error`'s `ExceptionClass`) across a Magnus call boundary —
the source of a real prior GC-safety segfault. `magnus::Error` construction
happens only after `rb_thread_call_without_gvl` returns, GVL held again.

## Rationale

- **GVL-release alone fails**: an `async` reactor (Falcon) cooperatively
  schedules Fibers on a *single OS thread*. Releasing the GVL only lets
  *other OS threads* progress — it doesn't free the thread still physically
  executing `duckling_parse`'s machine code, so the ticker Fiber sharing
  that thread never runs. `rb_thread_call_without_gvl` alone failed on both
  Ruby 3.3.6 and 3.4.5 (`max_gap` tracked `parse_duration` almost exactly —
  see [Raw measurements](../research/fiber-scheduler-mechanism-spike/results.md#approach-a-alone-rb_thread_call_without_gvl-around-duckling_parse-no-ruby-level-thread-spawn)).
  Ruby 3.4's `Fiber::Scheduler#blocking_operation_wait` doesn't rescue this:
  it only fires when the lower-level `rb_nogvl` is called with
  `RB_NOGVL_OFFLOAD_SAFE`, which `rb_thread_call_without_gvl` never sets
  (confirmed against [`ruby/ruby`'s `thread.c` at `v3_4_5`](https://github.com/ruby/ruby/blob/v3_4_5/thread.c#L1686-L1690));
  that flag doesn't exist pre-3.4, ruling it out on this gem's `>= 3.2.0` floor.
- **A background Thread alone also fails**: `Thread.new { ... }.value`
  around the *unmodified* call (GVL still held) also failed — a second OS
  thread exists but holds the GVL for the whole call, so the reactor's own
  OS thread has no safepoint to reclaim it at (see
  [Raw measurements](../research/fiber-scheduler-mechanism-spike/results.md#approach-b-alone-background-thread-but-gvl-not-released-in-the-native-call)).
  Only the combination passed: releasing the GVL makes the background
  thread's blocking window non-exclusive, and `Thread#value`'s
  `block`/`unblock` scheduler hooks — present since Ruby 3.0, unlike
  `blocking_operation_wait` — let the *calling* Fiber yield to the reactor.
- **Thread-per-call over a worker pool**: issue #57 has no
  throughput-optimization goal in scope. Thread-per-call gets
  panic/exception propagation for free via `Thread#value`'s re-raise
  semantics, whereas a worker pool must hand-roll rescue/repost/re-raise. A
  pool's lifecycle questions (eager/lazy start, `at_exit` shutdown,
  in-flight work on exit) are real design surface thread-per-call
  sidesteps entirely. See the
  [comparison table](../research/concurrency-alternatives-comparison/README.md#comparison)
  and [Thread-Per-Call Dispatch](../research/concurrency-alternatives-comparison/thread-per-call.md).
  Measured spawn overhead (~70µs/thread) is a rounding error against most
  real calls (690µs–3.8ms) but proportionally significant on the fastest
  (`empty` at 24.1µs) — see Open Questions.
- **Safe to run concurrently**: [duckling](https://github.com/wafer-inc/duckling)'s
  `parse` entrypoint has no unsynchronized global mutable state — every
  process-wide cache is `Mutex`/`OnceLock`-guarded, held only for a brief
  lookup/insert; every type crossing the public API is `Send + Sync`; the
  crate's one non-`Send` type (`Rc<Node>`) never escapes a single call (see
  [Global Mutable State Audit](../research/duckling-crate-thread-safety/global-state-audit.md)).
  Worst case under a race is a redundant cache rebuild, not corruption.
- **Panic guard must be unconditional**: [duckling](https://github.com/wafer-inc/duckling)'s
  own two-layer `catch_unwind` is compiled out entirely under
  `#[cfg(not(debug_assertions))]` — absent in Cargo's `dev` profile, this
  repo's own local default (`.env.local.example` sets
  `RB_SYS_CARGO_PROFILE=dev`). Only CI and `rake release` get the wrapped
  crate's internal guard for free, so the wrapper cannot rely on it — see
  [Panic Safety and catch_unwind](../research/duckling-crate-thread-safety/panic-safety.md).

## Steps

For the eventual implementation PR (not this one):

1. In `ext/duckling/src/lib.rs`, add a `ParsePayload` struct (owned
   `text`/`locale`/`dims`/`context`/`options` in;
   `Option<Result<Vec<Entity>, String>>` out) and an
   `unsafe extern "C" fn parse_without_gvl(*mut c_void) -> *mut c_void`
   callback running `duckling_parse(...)` inside `std::panic::catch_unwind`,
   per the [implementation sketch](../research/magnus-rb-sys-gvl-release/implementation-sketch.md).
2. Replace `parse`'s single `duckling_parse(...)` line with:
   `Box::into_raw` the payload, call
   `rb_sys::rb_thread_call_without_gvl(Some(parse_without_gvl), payload_ptr, None, ptr::null_mut())`,
   then `Box::from_raw` to reclaim it. No `Cargo.toml` change is needed —
   `rb-sys` already exposes this unconditionally through the existing
   `stable-api-compiled-fallback` feature (see
   [The Raw `rb_thread_call_without_gvl` FFI Surface](../research/magnus-rb-sys-gvl-release/raw-ffi-signature.md#the-exact-generated-rust-signature-verified-against-this-repos-own-build)).
3. On the `Err(message)` branch, construct `magnus::Error::new(ruby.exception_fatal(), ...)`
   only after the box is reclaimed (GVL confirmed held) — never inside
   `parse_without_gvl`.
4. Decide the native entrypoint's name/visibility: it can't be what
   `Duckling.parse` calls directly once the Thread-spawn moves to Ruby (see
   Open Questions) — likely a renamed private binding (the spike's
   throwaway prototype used `_native_parse_spike`; pick a real name).
5. In `lib/duckling.rb`, define `Duckling.parse` to do
   `Thread.new { <native binding>(*args, **kwargs) }.value`, matching the
   spike's passing "Approach A+B combined" shape.
6. Decide where arg validation/conversion (`scan_args`/`get_kwargs`,
   `parse_locale`/`parse_dims`/`build_context`) runs relative to the
   Thread-spawn — see
   [Thread-Per-Call Dispatch's "Where argument conversion happens"](../research/concurrency-alternatives-comparison/thread-per-call.md#where-argument-conversion-happens)
   for the two candidate shapes; converting on the calling thread first
   (shape 2) is the safer default. The spike's own passing prototype used
   shape 1 (whole native call, including arg parsing, inside `Thread.new`);
   shape 2 needs re-verifying against `test/falcon_fiber_blocking_test.rb`,
   not assumed to pass unchanged.
7. Run `test/falcon_fiber_blocking_test.rb` and confirm it flips from
   failing to passing; re-run `test/duckling_test.rb` and
   `test/duckling_comma_list_test.rb` to confirm return values are
   unchanged (the spike did this for every prototype variant and stayed
   green throughout), then run the full `bundle exec rake` (`standard` +
   `compile` + `test`) before opening the implementation PR. Per
   [Test-and-CI Mechanics](../research/test-and-ci-mechanics/README.md#what-needs-to-change-if-anything-before-an-implementation-pr-can-rely-on-this-test-passing-in-ci),
   no `.github/workflows/main.yml` or `bin/claude-web-deps.sh` change is
   needed — the code fix is the only thing standing between this branch and
   a green CI run on this test.
8. File the deferred items rather than resolving them silently: no `ubf`
   cancellation hook for `Thread#raise`/`Thread#kill` against an in-flight
   parse, and whether GVL release/reacquire is worth it for calls this
   short (both noted in
   [magnus-rb-sys-gvl-release's Open follow-ups](../research/magnus-rb-sys-gvl-release/README.md#open-follow-ups)).

## Open questions

- **Where should the Thread-spawn live — Rust or Ruby?** The spike only
  prototyped the Ruby-level wrapper; it explicitly did not prototype
  spawning via Magnus's `Ruby::thread_create_from_fn` from Rust, noting
  it's "worth a quick ergonomics comparison before implementation" if the
  fix wants to avoid a public-API rename (see
  [fiber-scheduler-mechanism-spike's Open follow-ups](../research/fiber-scheduler-mechanism-spike/README.md#open-follow-ups)).
  This plan recommends the Ruby-level wrapper as the default — it's the
  variant actually measured passing, and avoids `thread_create_from_fn`'s
  `'static + Send + FnOnce` bound complications (see
  [The Raw `rb_thread_call_without_gvl` FFI Surface](../research/magnus-rb-sys-gvl-release/raw-ffi-signature.md#magnus-082-has-no-safe-wrapper)) —
  but the comparison itself hasn't been done.
- **Downside for non-reactor callers** (a plain synchronous script, or a
  Puma app with no `Fiber::Scheduler` registered)? Every call pays ~70µs of
  thread overhead even with no reactor to unblock. Per the benchmark-ips
  scenarios in
  [Concurrency Alternatives Comparison](../research/concurrency-alternatives-comparison/README.md#where-todays-implementation-stands),
  that's negligible against `short`/`medium`/`long` calls (690µs–3.8ms) but
  plausibly doubles or triples latency on the fastest ones (`empty` at
  24.1µs). No research topic investigated conditionally skipping the
  Thread-spawn (e.g. checking `Fiber.scheduler` at call time) — this bears
  on whether dispatch should be unconditional or configurable (an opt-out
  via env var, keyword arg, or scheduler-presence check), which is an open
  design choice this research didn't settle either way.
- **Argument-conversion shape** (Steps #6, calling vs. spawned thread) is
  flagged by its own source document as "a design decision for whichever
  topic actually implements the fix, not settled here." Relatedly,
  `Thread#value` exception propagation interacting with the existing
  `ArgumentError` paths (`parse_locale`/`parse_dims`/`build_context`)
  wasn't specifically exercised beyond the suite staying green across
  prototypes — deserves an explicit test in the real fix (see
  [fiber-scheduler-mechanism-spike's Open follow-ups](../research/fiber-scheduler-mechanism-spike/README.md#open-follow-ups)).
- **No `ubf` cancellation hook**, and **whether GVL release/reacquire is
  worth its cost** for a ~500µs–3ms call, are carried over unresolved from
  the Rust-mechanics research (Steps #8) — still-open, not implicitly
  decided by this plan.
