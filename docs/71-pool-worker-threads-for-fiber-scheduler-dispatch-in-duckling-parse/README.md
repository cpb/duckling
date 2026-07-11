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

**A pool can drive per-call `Thread.new` down to zero.** A direct spike
([hand-rolled-pool §3](research/hand-rolled-pool/README.md#3-the-fiber-cooperation-mechanism-empirically-verified))
showed that a bare `Queue#pop` (and `Mutex#lock`, `ConditionVariable#wait`)
called on the calling Fiber's own thread already cooperates with
`Fiber.scheduler` — the reactor keeps running while the Fiber waits. So the
calling Fiber can block directly on a per-call reply queue, with no per-call
wait-wrapper thread. This is a strict improvement over today's
`Thread.new { Native.parse(...) }.value`, which spawns one thread per call.

`concurrent-ruby`'s `Future#value` reaches the same zero-thread floor
(it waits on `Mutex`+`ConditionVariable` underneath —
[verified](research/concurrent-ruby-executors/README.md#empirical-verification-does-futurevalue-cooperate-with-fiberscheduler)),
so Fiber-cooperation doesn't distinguish the two pool options. The
[plan](plans/01-pool-design-recommendation.md) recommends the **hand-rolled
stdlib pool** on the axis that does distinguish them: it adds no runtime
dependency (this gem prizes its single-dependency posture), covering the
pool/shutdown mechanics in under 100 lines, where `concurrent-ruby` would be
a new dependency buying only that same mechanics.
