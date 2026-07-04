# Issue #77 — Spike: does `rb_nogvl` + `RB_NOGVL_OFFLOAD_SAFE` obviate the Thread wrapper?

## Verdict: CONFIRMED

Calling the lower-level `rb_nogvl` directly with the `RB_NOGVL_OFFLOAD_SAFE` flag (instead of the
`rb_thread_call_without_gvl` convenience wrapper duckling currently uses) does let a
`Fiber::Scheduler`'s `blocking_operation_wait` hook auto-offload the blocking `duckling::parse`
call — on Ruby 3.4+, with no Ruby-level `Thread.new` wrapper needed. This was confirmed two ways:
a decisive mechanism-level test on Ruby 3.4.10 (a hand-rolled scheduler directly counting hook
invocations) and a practical end-to-end test on Ruby 4.0.5 (the real `async` gem's own automatic
offload path). See [research/README.md](research/README.md) for the full methodology and
[research/results.md](research/results.md) for the raw data.

**Important caveat**: the real `async`/`io-event` gem stack can only exercise this automatically
starting **Ruby 4.0**, not 3.4 — see "Critical finding" below. On Ruby 3.4.x, the mechanism itself
works (confirmed via the hand-rolled scheduler), but `async`-based callers won't benefit from it
until they're also on Ruby 4.0.

## Background

[`ext/duckling/src/lib.rs`](https://github.com/cpb/duckling/blob/main/ext/duckling/src/lib.rs)'s
`parse` releases the GVL via `rb_sys::rb_thread_call_without_gvl`, which always calls
`rb_nogvl(..., flags: 0)` internally. Because the flag is never set, `lib/duckling.rb`'s
`Duckling.parse` has to manually detect an installed `Fiber.scheduler` and spawn a real background
`Thread.new { Native.parse(...) }.value` so a single-OS-thread async reactor Fiber can yield — a
bare GVL release alone doesn't unblock it (see the wiki's
[research-async-reactor-blocking](https://github.com/cpb/duckling/wiki/research-async-reactor-blocking)
for that history). `docs/2026-07-01-roadmap.md`'s "Ruby version floor" bullet flagged this as an
open question but it was never prototyped — this spike (issue #77) prototypes it.

## Critical finding

The issue's literal acceptance criteria named Ruby 3.4.10 and `test/falcon_fiber_blocking_test.rb`
(which uses the `async` gem). Running that combination alone would have been misleading: `async`'s
own automatic `blocking_operation_wait` offload requires `io-event`'s `WorkerPool`, which requires
the C API `rb_fiber_scheduler_blocking_operation_extract` — present in Ruby 4.0's headers, **absent
from every 3.4.x/3.3.x/3.2.x Ruby** (verified directly across every locally-installed rbenv
version). So the spike ran two tracks instead of one — see
[research/README.md](research/README.md#two-track-methodology) for why, and
[research/results.md](research/results.md) for both tracks' full data.

## Reading order

| Document | Covers |
|---|---|
| [research/README.md](research/README.md) | Methodology: the `io-event`/Ruby-4.0 structural finding, the two-track design, and the verdict reasoning |
| [research/results.md](research/results.md) | Raw per-experiment data from both tracks |

## Follow-up

This spike's CONFIRMED verdict meets all of the plan's criteria for recommending a follow-up
implementation issue (see [research/README.md](research/README.md#follow-up-scoping) for what it
should scope in). Per this issue's own "Notes" section, opening that issue is deferred to PR
review — not created by this spike itself.
