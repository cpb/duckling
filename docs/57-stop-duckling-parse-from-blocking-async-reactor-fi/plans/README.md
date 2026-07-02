# Plans: Stop `Duckling.parse` from Blocking the Async Reactor

Breadth-first summary of the two plan documents synthesizing the
[research](../research/README.md) for issue
[#57](https://github.com/cpb/duckling/issues/57) into a concrete,
recommended approach. Neither plan changes application code — both are
scoped to a future implementation PR that hasn't been built yet.

Together they recommend: in `ext/duckling/src/lib.rs`, convert Ruby
arguments to owned Rust data, then call the raw `rb_thread_call_without_gvl`
FFI binding (guarded by `std::panic::catch_unwind`, since Magnus's own
automatic panic wrapping doesn't reach inside a raw off-GVL callback) around
`duckling::parse`, dispatched via an unconditional per-call background
`Thread` spawn at the Ruby level — because the empirical research showed a
bare GVL release, without also moving the call onto a separate OS thread,
does not stop the reactor from stalling on this gem's Ruby floor.

## Table of contents

| Document | Summary |
|---|---|
| [Plan: GVL-Release Implementation for `Duckling.parse`](01-gvl-release-implementation.md) | The concrete Rust/Ruby implementation shape: `rb_thread_call_without_gvl` + `std::panic::catch_unwind` in `ext/duckling/src/lib.rs`, dispatched via a spawned `Thread`. |
| [Thread Dispatch Strategy for `Duckling.parse`](02-thread-dispatch-strategy.md) | Whether every `Duckling.parse` call should spawn a thread unconditionally or opt out when no Fiber scheduler is present — recommends unconditional spawning for simplicity, with the opt-out deferred as scoped future work. |

## Reading order

1. [Plan: GVL-Release Implementation for `Duckling.parse`](01-gvl-release-implementation.md) — the primary decision and implementation steps.
2. [Thread Dispatch Strategy for `Duckling.parse`](02-thread-dispatch-strategy.md) — a deeper look at one specific sub-decision (unconditional vs. opt-out dispatch) referenced by the first plan.
