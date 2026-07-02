# Research: Stop `Duckling.parse` from Blocking the Async Reactor

Breadth-first summary of the terrain mapped for issue
[#57](https://github.com/cpb/duckling/issues/57): `Duckling.parse` is a
synchronous Rust FFI call that holds Ruby's GVL for its full duration, which
stalls sibling `Fiber`s inside an `Async::Reactor` (e.g. Falcon), as proven
empirically by `test/falcon_fiber_blocking_test.rb`. Five topics were
researched in parallel to determine what a fix needs to do, whether it's
safe, and whether the surrounding test/CI tooling is ready for it.

The single most load-bearing finding across all five topics: **releasing the
GVL alone is not sufficient**. [Fiber-Scheduler Mechanism Spike](fiber-scheduler-mechanism-spike/README.md)
empirically proved that a fix needs *both* a raw GVL release *and* a
genuine background `Thread` spawn, because this gem's Ruby floor (`>= 3.2.0`,
CI pins `3.3.6`) predates the VM feature (`Fiber::Scheduler#blocking_operation_wait`,
Ruby 3.4+) that would otherwise make a bare GVL release sufficient.

## Table of contents

| Document | Summary |
|---|---|
| [Releasing the GVL Around `duckling::parse` with Magnus + rb-sys](magnus-rb-sys-gvl-release/README.md) | How to release Ruby's GVL with this gem's pinned Magnus 0.8.2 + rb-sys 0.9.128 — Magnus has no safe wrapper, so the fix drops to the raw `rb_thread_call_without_gvl` FFI binding. |
| [Duckling Crate Thread-Safety](duckling-crate-thread-safety/README.md) | Confirms the wrapped [duckling](https://github.com/wafer-inc/duckling) 0.4.0 crate has no unsynchronized global state and is safe to call concurrently — but its own panic-catching is release-profile-only. |
| [Fiber-Scheduler Mechanism Spike](fiber-scheduler-mechanism-spike/README.md) | Empirically prototyped and measured which mechanism actually stops the reactor from stalling — GVL release alone fails even on Ruby 3.4.5; GVL release + a spawned `Thread` passes 11/11 runs. |
| [Concurrency Alternatives Comparison](concurrency-alternatives-comparison/README.md) | Compares thread-per-call vs. a persistent worker-pool vs. process isolation for dispatching the call off the calling Fiber's thread, and recommends thread-per-call. |
| [Test-and-CI Mechanics for `falcon_fiber_blocking_test.rb`](test-and-ci-mechanics/README.md) | Confirms the existing hill-first test and its new `async ~> 2.41` dev-dependency are already fully compatible with CI and the Claude Code Web JIT-dependency-install path — nothing needs to change there. |

## Reading order

1. [Duckling Crate Thread-Safety](duckling-crate-thread-safety/README.md) — establishes the precondition (is this even safe?) before the mechanism topics.
2. [Releasing the GVL Around `duckling::parse` with Magnus + rb-sys](magnus-rb-sys-gvl-release/README.md) — the Rust/Magnus "how."
3. [Fiber-Scheduler Mechanism Spike](fiber-scheduler-mechanism-spike/README.md) — the empirical "does it actually work" check, and why the naive answer is wrong.
4. [Concurrency Alternatives Comparison](concurrency-alternatives-comparison/README.md) — given the spike's finding, how to dispatch onto a background thread.
5. [Test-and-CI Mechanics for `falcon_fiber_blocking_test.rb`](test-and-ci-mechanics/README.md) — independent of the above; confirms tooling readiness.
