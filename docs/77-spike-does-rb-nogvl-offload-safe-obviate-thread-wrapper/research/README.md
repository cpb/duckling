# Research: `rb_nogvl` + `RB_NOGVL_OFFLOAD_SAFE` mechanism spike

## Table of contents

| Document | Covers |
|---|---|
| [results.md](results.md) | Raw per-experiment data tables for both tracks below |

## Starting point

`ext/duckling/src/lib.rs`'s `parse` function releases the GVL via:

```rust
rb_sys::rb_thread_call_without_gvl(Some(parse_without_gvl), &mut payload as *mut _, None, std::ptr::null_mut());
```

`rb_thread_call_without_gvl` is a convenience wrapper that always calls the lower-level
`rb_nogvl(..., flags: 0)` internally. `rb-sys 0.9.128` (the version this gem resolves to, per
`Cargo.lock`) also exposes `rb_nogvl` directly, plus its flag constants:

```rust
pub const RB_NOGVL_INTR_FAIL: u32 = 1;
pub const RB_NOGVL_UBF_ASYNC_SAFE: u32 = 2;
pub const RB_NOGVL_OFFLOAD_SAFE: u32 = 4;
```

The question: does calling `rb_nogvl` directly with `flags: RB_NOGVL_OFFLOAD_SAFE` let Ruby 3.4's
`Fiber::Scheduler#blocking_operation_wait` auto-offload the call, obviating `lib/duckling.rb`'s
Ruby-level `Thread.new { Native.parse(...) }.value` dispatch?

## The prototype

A throwaway entrypoint, `Duckling::Native.parse_nogvl_offload`, was added to
`ext/duckling/src/lib.rs` alongside the existing `parse`, reusing the same `ParsePayload` struct
and `parse_without_gvl` callback verbatim — the only difference is the FFI dispatch call:

```rust
unsafe {
    rb_sys::rb_nogvl(
        Some(parse_without_gvl),                 // same callback as `parse`
        &mut payload as *mut ParsePayload as *mut c_void,
        None,                                     // ubf — no cancellation hook, matches `parse`
        std::ptr::null_mut(),
        rb_sys::RB_NOGVL_OFFLOAD_SAFE as std::os::raw::c_int,
    );
}
```

`ubf` was kept `None` and `RB_NOGVL_UBF_ASYNC_SAFE` was deliberately not set — that flag describes
a property of a supplied `ubf` callback (safe to invoke from arbitrary/signal contexts), which is
meaningless when `ubf` is `None`, and setting it would have conflated cancellation semantics with
the one variable this spike needed to isolate.

This entrypoint was **discarded** before this PR was opened — it never shipped, per the issue's
"Out of scope" section. `research/results.md` records everything measured while it existed.

## Two-track methodology

The issue's acceptance criteria named Ruby 3.4.10 and running
`test/falcon_fiber_blocking_test.rb` (which uses the `async` gem, pinned to `2.42.0`). Before
trusting that alone, the actual mechanism `async` relies on for auto-offload was checked directly:

1. `async 2.42.0`'s `Async::Scheduler#blocking_operation_wait` is only defined on an instance when
   `io-event`'s `IO::Event::WorkerPool` is available (`lib/async/scheduler.rb` in the installed
   gem, opt-in via the `ASYNC_SCHEDULER_WORKER_POOL` env var).
2. `io-event 1.19.1`'s `ext/extconf.rb` only compiles `WorkerPool` support
   (`-DHAVE_IO_EVENT_WORKER_POOL`, `worker_pool.c`) when
   `have_func("rb_fiber_scheduler_blocking_operation_extract")` succeeds.
3. That C function is declared in `ruby/fiber/scheduler.h`. Grepping every Ruby version installed
   locally via rbenv (3.2.2, 3.3.6, 3.3.8, 3.4.4, 3.4.5, 3.4.10, 4.0.5) found it **only in Ruby
   4.0.5's headers** — absent from every 3.4.x/3.3.x/3.2.x install. A live `have_func` check
   confirmed it links successfully on 4.0.5 and fails to link on 3.4.10.
4. Separately, `docs.ruby-lang.org`'s Ruby 3.2 vs 3.4 `Fiber::Scheduler` API docs confirm the
   **Ruby-level** `blocking_operation_wait(work)` hook itself was added in Ruby 3.4 (absent from
   3.2's page, present on 3.4's). Ruby's own reference scheduler
   ([`ruby/ruby`'s `test/fiber/scheduler.rb`](https://github.com/ruby/ruby/blob/v3_4_10/test/fiber/scheduler.rb))
   implements it as exactly `Thread.new(&work).join` — the hook exists on 3.4+, but the automatic
   C-level extraction `io-event` needs to wire it up transparently for `async`/Falcon users only
   ships in Ruby 4.0.

So running only the prescribed `async`-gem test on 3.4.10 would always fail/stall regardless of
duckling's native code — it would not be a valid test of the `rb_nogvl` flag on that floor. Two
tracks were run instead:

- **Track 2 (decisive, Ruby 3.4.10 — the issue's named target)**: a hand-rolled
  `Fiber::Scheduler`, adapted directly from Ruby's own reference scheduler
  (`ruby/ruby`'s `test/fiber/scheduler.rb` at tag `v3_4_10`), instrumented to count
  `blocking_operation_wait` invocations directly — bypassing `io-event` entirely. This isolates
  whether `rb_nogvl` with `RB_NOGVL_OFFLOAD_SAFE` invokes the hook at all, independent of
  `io-event`'s Ruby-4.0 requirement.
- **Track 1 (practical, Ruby 4.0.5 — also available locally via rbenv)**: the issue's
  literally-described `test/falcon_fiber_blocking_test.rb`-style test via the real `async` gem,
  with `ASYNC_SCHEDULER_WORKER_POOL=true` set. Ruby 4.0.5 is the only locally-installed Ruby where
  `io-event`'s `WorkerPool` compiles, so this is the only version where the real reactor stack can
  exercise the mechanism at all — confirmed live (`have_func` succeeds on 4.0.5,
  `Async::Scheduler.new.respond_to?(:blocking_operation_wait)` is `true` with the env var set).

## Results summary

Both tracks confirm the mechanism, consistently across 5+ repeated runs each (see
[results.md](results.md) for every row and repeat):

- **Track 2, row (e) control** (`flags: 0`, i.e. today's `rb_thread_call_without_gvl`):
  `blocking_operation_wait_calls == 0` every run; ticker gap ≈ full `parse_duration` (reactor
  stalls) — matches the known pre-#64 blocking signature.
- **Track 2, row (f) decisive** (`RB_NOGVL_OFFLOAD_SAFE` set): `blocking_operation_wait_calls == 1`
  every run; ticker gap ≈ 1-2ms regardless of `parse_duration` (≈50-130ms) — the reactor does not
  stall. The hook fires and achieves real non-blocking dispatch, not just an invocation with no
  effect.
- **Root-fiber variant**: calling `parse_nogvl_offload` from the root fiber (not a
  `Fiber.schedule`-spawned one), with a scheduler installed but idle, produced
  `blocking_operation_wait_calls == 0` — the hook only fires for fiber-scheduled call stacks. This
  matches how `Duckling.parse` would actually be invoked inside a reactor (always from a scheduled
  Fiber), so it isn't a practical limitation.
- **Track 1, rows (a)/(b)** (baseline sanity, real `async` gem on Ruby 4.0.5): (a)
  `parse`+Thread-wrapper passes; (b) `parse` without the wrapper fails/stalls — reconfirms #64's
  existing necessity absent the flag, on this Ruby floor too.
- **Track 1, row (c) — key** (`parse_nogvl_offload`, no Thread wrapper): **passes**, consistently
  across 4 repeated runs — the real `async`/`io-event` stack auto-offloads the call via the flag
  alone, no Ruby-level Thread wrapper needed, on Ruby 4.0.5.
- **Track 1, row (d)** (`parse_nogvl_offload` + Thread wrapper, sanity): passes — the new
  entrypoint doesn't regress when combined with the existing wrapper.
- **Correctness**: `test/duckling_test.rb` + `test/duckling_comma_list_test.rb` (9 tests, 55
  assertions) pass with zero failures/errors when `Duckling::Native.parse` is aliased to
  `parse_nogvl_offload`, on both Ruby 3.4.10 and Ruby 4.0.5 — the alternate FFI dispatch produces
  identical results to the shipped `parse`.

## Follow-up scoping

All of the plan's CONFIRMED criteria were met (hook fires only with the flag set, ticker doesn't
stall, correctness suite stays green on both Ruby versions tested), so this spike's finding
warrants a follow-up implementation issue rather than being closed as refuted. That issue should
scope in:

- Version-gating the new dispatch path on `RUBY_VERSION >= "3.4"` (matching Ruby's own addition of
  the `blocking_operation_wait` hook), while being explicit that `async`/Falcon-based callers won't
  actually benefit until they're *also* on Ruby 4.0 — the mechanism works on 3.4+, but `io-event`'s
  `WorkerPool` (what wires it up transparently for the real gem most callers use) doesn't compile
  until Ruby 4.0, per the finding above. Callers of a hand-rolled or other `blocking_operation_wait`
  implementation benefit starting 3.4.
- Whether a single precompiled binary shared across Ruby 3.2+ (this gem's actual ship model, via
  `stable-api-compiled-fallback`) can safely reference `rb_nogvl` unconditionally. `rb_nogvl` itself
  (unlike the *effect* of the `RB_NOGVL_OFFLOAD_SAFE` flag) has existed since Ruby 2.6 — well below
  this gem's `>= 3.2.0` floor — so the symbol-resolution risk that motivated splitting this out as
  an open question is low, but the follow-up issue should confirm this explicitly (e.g. against the
  oldest supported Ruby in `cross-gem.yml`'s build images) rather than assume it.
- Not bumping `required_ruby_version` — this spike's finding supports adding a *conditional* faster
  path on 3.4+, not raising the floor.
