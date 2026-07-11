# Research: pool worker threads for Fiber-scheduler dispatch (issue #71)

Five research topics map the terrain for replacing `Duckling.parse`'s
per-call `Thread.new { Native.parse(...) }.value` spawn with a reusable
worker pool. Two cover candidate pool designs, one surveys the rest of the
gem landscape, one documents today's dispatch code as the baseline, and one
covers how to measure the result.

## Table of contents

| Doc | Summary |
|---|---|
| [concurrent-ruby-executors/README.md](concurrent-ruby-executors/README.md) | `Concurrent::FixedThreadPool` + `Future` cleanly satisfies configurable-size and synchronous-result needs without touching the Rust GC-safety boundary; `Future#value` cooperates with `Fiber.scheduler` (verified), reaching zero per-call threads — but it adds a new runtime dependency and a `Thread.list`/shutdown hygiene concern. |
| [hand-rolled-pool/README.md](hand-rolled-pool/README.md) | A stdlib-only `Queue` + fixed-worker-array pool is dependency-free, doesn't touch the GC-safety boundary, and (verified by spike) needs **zero** per-call threads: a bare `Queue#pop` on the calling Fiber cooperates with `Fiber.scheduler`, so the caller pops the reply queue directly. |
| [other-gems-landscape/README.md](other-gems-landscape/README.md) | Every standalone Ruby thread-pool gem besides `concurrent-ruby` (`workers`, `dat-worker-pool`, `threadpool`, `ruby_thread_pool`, `em-worker-pool`, `thread_pool`) is dormant since 2012–2020 with no Dependabot config — the real choice is `concurrent-ruby` vs. hand-rolled. |
| [current-dispatch-terrain/README.md](current-dispatch-terrain/README.md) | Baseline: the exact dispatch code in `lib/duckling.rb` and the GVL-release/`ParsePayload`/panic-catching mechanism in `ext/duckling/src/lib.rs`, why a bare GVL release doesn't unblock a Fiber::Scheduler, both existing dispatch tests' assertions, the GC-safety constraint, and current per-scenario benchmark overhead (up to +948% on `empty`). |
| [benchmark-methodology/README.md](benchmark-methodology/README.md) | Traces issue #71's cited "+53% to +965%" figures to their exact source (a pre-fix recording), pulls current post-fix baselines, and lays out three options for adding a pooled-dispatch benchmark scenario to the existing `parse_benchmark.rb`/`docs/benchmarks/` pipeline. |

## Cross-cutting finding

The GC-safety boundary (no `magnus::Value`/`magnus::Error` crossing threads)
is identical across every candidate — it's already fully satisfied inside
`Native.parse`'s existing `ParsePayload` design and is unaffected by which
Ruby-level thread calls it. Pooling **can** reduce per-call thread spawning
to zero, and equally so for both candidate designs: a spike confirmed that
`Queue#pop`/`Mutex#lock`/`ConditionVariable#wait` (and `concurrent-ruby`'s
`Future#value`, built on them) cooperate with `Fiber.scheduler` when called
on the calling Fiber's own thread, so the caller waits on the reply channel
directly with no per-call `Thread.new` — see
[hand-rolled-pool §3](hand-rolled-pool/README.md#3-the-fiber-cooperation-mechanism-empirically-verified).
Because Fiber-cooperation is a wash, the axis that actually discriminates
between the two pool candidates is **dependency footprint** (stdlib vs. a new
runtime gem). See [current-dispatch-terrain](current-dispatch-terrain/README.md)
for why a bare GVL release alone was never sufficient to begin with.
