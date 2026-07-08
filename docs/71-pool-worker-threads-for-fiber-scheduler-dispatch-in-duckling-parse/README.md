# Issue #71: Pool worker threads for Fiber-scheduler dispatch in Duckling.parse

Research-and-planning artifacts for
[issue #71](https://github.com/cpb/duckling/issues/71): replace the per-call
`Thread.new { Native.parse(...) }.value` spawn in `Duckling.parse`'s
Fiber-scheduler dispatch path (`lib/duckling.rb`) with a reusable worker
thread pool, so Fiber runtimes (e.g. Falcon/Async) get non-blocking dispatch
without paying a fresh OS-thread-spawn cost on every call.

This issue is labeled `test-first`: implementation is gated behind a
separate `/hill-first` session that writes failing tests first, after an
operator reviews a draft PR. This PR's job is to map the terrain and propose
a grounded plan for that future session — it contains no implementation or
test code.

## Reading order

1. [`research/README.md`](research/README.md) — start here for a breadth-first
   summary of all five research topics.
2. [`plans/README.md`](plans/README.md) — the single design recommendation,
   grounded in the research above.

## Table of contents

| Doc | What it covers |
|---|---|
| [research/README.md](research/README.md) | Index of all research topics |
| [research/concurrent-ruby-executors/README.md](research/concurrent-ruby-executors/README.md) | `concurrent-ruby`'s thread pool executors as a pooling candidate |
| [research/hand-rolled-pool/README.md](research/hand-rolled-pool/README.md) | A stdlib-only `Queue`-based pool as a pooling candidate |
| [research/other-gems-landscape/README.md](research/other-gems-landscape/README.md) | Survey of every other standalone Ruby thread-pool gem |
| [research/current-dispatch-terrain/README.md](research/current-dispatch-terrain/README.md) | Baseline: today's dispatch code, GVL-release mechanism, and existing tests |
| [research/benchmark-methodology/README.md](research/benchmark-methodology/README.md) | The existing benchmark pipeline and how to measure a pooled scenario against it |
| [plans/README.md](plans/README.md) | Index of plans |
| [plans/01-pool-design-recommendation.md](plans/01-pool-design-recommendation.md) | Decision, rationale, steps, and open questions for the pool design |

## Headline finding

**Update: the finding below has been superseded by a follow-up spike — see
the flag in [plans/01-pool-design-recommendation.md](plans/01-pool-design-recommendation.md#decision)
and the empirical verification sections in
[research/hand-rolled-pool](research/hand-rolled-pool/README.md#empirical-verification-bare-queuepopmutexlockconditionvariablewait-are-fiber-scheduler-hooked)
and
[research/concurrent-ruby-executors](research/concurrent-ruby-executors/README.md#empirical-verification-does-futurevalue-cooperate-with-fiberscheduler).
Kept below for the historical reasoning trail; needs operator review before
the plan's Decision is treated as final.**

The research surfaced a finding sharper than "which library to use": **no
candidate — library or hand-rolled — is proven to eliminate per-call thread
spawning**, since only `Thread#value`/`Thread#join`-shaped waits cooperate
with `Fiber.scheduler`, not a bare `Queue#pop`. The
[plan](plans/01-pool-design-recommendation.md) recommends a hand-rolled
stdlib pool specifically because its version of that limit is mechanically
proven, where `concurrent-ruby`'s equivalent (`Future#value`) is an
unverified hypothesis.

Both halves of that finding turned out to be wrong on closer inspection: a
direct spike showed a bare `Queue#pop` on the calling Fiber's own thread
*does* cooperate with `Fiber.scheduler` (no wrapper thread needed), and
`concurrent-ruby`'s `Future#value` cooperates too (transitively, via
`Mutex`/`ConditionVariable`). See the empirical verification sections
linked above for the numbers.
