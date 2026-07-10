# Plan: pool design recommendation for issue #71

Terrain for the future `/hill-first` test-writing session, not something to
implement directly from this PR (issue #71 is labeled `test-first`).

## Decision

Build a **hand-rolled, stdlib-only `Queue`-based worker pool** in-repo
(`Duckling::Pool` or similar), not `concurrent-ruby`. Do not adopt any other
standalone thread-pool gem — none is a live candidate (see Rationale).

The design reaches **zero per-call `Thread.new`**: under a `Fiber.scheduler`,
`Duckling.parse` submits the job to a pre-warmed worker and blocks the
calling Fiber directly on a per-call reply `Queue#pop`, which is
scheduler-hooked (empirically verified — see the crux below). This is
strictly better than today's per-call `Thread.new{...}.value`, which spawns
one thread per call.

## Rationale

**Maintenance/adoption signal** rules out everything except `concurrent-ruby`
as a library option: every other standalone thread-pool gem (`workers`,
`dat-worker-pool`, `threadpool`, `ruby_thread_pool`, `em-worker-pool`,
`thread_pool`) is dormant since 2012–2020, with no Dependabot config and no
commits in 6+ years —
[other-gems-landscape](../research/other-gems-landscape/README.md#ranking-most-to-least-actively-maintainedadopted).
So the real choice is `concurrent-ruby` vs. hand-rolled, exactly as both
sibling docs frame it.

**GC-safety fit**: identical for both options. The "no `magnus::Value`/
`magnus::Error` crosses the pool boundary" constraint is already fully
satisfied by `ParsePayload`'s existing design inside `Native.parse`
([current-dispatch-terrain §6](../research/current-dispatch-terrain/README.md#6-gc-safety-rule-no-magnusvaluemagnuserror-across-the-pool-boundary)).
A Ruby-level pool sitting in front of `Native.parse` — whether hand-rolled or
`concurrent-ruby`-backed — never touches that boundary; it only moves
ordinary Ruby objects (`String`, `Time`, `Array`, `Hash`) between `Thread`s
under the GVL, which is already safe today
([concurrent-ruby-executors "Does this change anything about the Ruby/Rust boundary?"](../research/concurrent-ruby-executors/README.md#does-this-change-anything-about-the-rubyrust-boundary),
[hand-rolled-pool "Native/GC-safety boundary"](../research/hand-rolled-pool/README.md#nativegc-safety-boundary-does-not-change-under-a-pool)).
This axis does not discriminate between the two options.

**Shutdown semantics**: hand-rolled wins on control, at the cost of owning
correctness. `concurrent-ruby`'s `FixedThreadPool` defaults workers to daemon
threads (`auto_terminate: true`), so the *process* won't hang on exit, but
`Thread.list` still shows the pool's threads for the life of the test process
unless explicitly shut down — a new hygiene concern
`test/thread_pool_dispatch_test.rb`'s existing spawn-counting technique
doesn't currently handle
([concurrent-ruby-executors "Thread lifecycle and shutdown semantics"](../research/concurrent-ruby-executors/README.md#thread-lifecycle-and-shutdown-semantics)).
A hand-rolled pool needs the same explicit-shutdown discipline, but the
poison-pill + `join` pattern is well under 100 lines and gives this repo
direct control over thread naming (`Thread#name=`) and exactly which
`Thread.new` calls happen, which matters for how
`thread_pool_dispatch_test.rb`'s `SpawnCounter` instrumentation reasons about
pool-worker creation vs. per-call spawns
([hand-rolled-pool §1, §4](../research/hand-rolled-pool/README.md#1-canonical-shape)).

**The crux: does pooling actually eliminate per-call `Thread.new`?**
Yes — **to zero**, and this is true for *both* pool options, so it does not
by itself pick between them. A direct spike settled two questions the earlier
version of this plan had left open:

- A bare `Queue#pop`/`Mutex#lock`/`ConditionVariable#wait` called on the
  calling Fiber's own OS thread **cooperates with `Fiber.scheduler`** — the
  reactor keeps running while the Fiber waits (measured ticker-gap ratio
  ~1.4% vs. ~100% for a genuine stall). So the calling Fiber can pop a
  per-call reply queue directly, with no per-call wait-wrapper `Thread`. The
  earlier assumption that "only `Thread#value`/`Thread#join` are
  scheduler-hooked, so one thread per call is the floor" was wrong: the hook
  surface also covers `Queue`/`Mutex`/`ConditionVariable`
  ([hand-rolled-pool §3](../research/hand-rolled-pool/README.md#3-the-fiber-cooperation-mechanism-empirically-verified)).
- `concurrent-ruby`'s `Future#value` cooperates too — it waits on a
  `Concurrent::Event` built on `Mutex`+`ConditionVariable`, the same hooked
  primitives — so a `concurrent-ruby`-backed pool reaches the same zero-
  per-call-thread floor
  ([concurrent-ruby-executors, empirical verification](../research/concurrent-ruby-executors/README.md#empirical-verification-does-futurevalue-cooperate-with-fiberscheduler)).

Because both options reach zero per-call threads, Fiber-cooperation is a
wash and the decision rests on the remaining axes above: **dependency
footprint and owned code**. `concurrent-ruby` would be a new runtime
dependency (this gem has exactly one today, `rb_sys`, called out in
`AGENTS.md`'s "Known gotchas" as needed even for precompiled consumers), and
it buys only pool/shutdown mechanics — which a `Queue` + fixed workers +
poison pill covers in well under 100 lines of stdlib. The one thing
`concurrent-ruby` would genuinely save (leak-free shutdown code this repo
would otherwise write and test itself) is outweighed by keeping the
single-runtime-dependency posture intact and retaining direct control over
exactly which `Thread.new` calls happen (which `thread_pool_dispatch_test.rb`
reasons about). Recommend building the pool in-repo.

## Steps

For the eventual `/hill-first` test-writing session and later implementation,
tied to issue #71's acceptance criteria:

1. **Pin the realistic acceptance bar before writing tests.** Pooling
   reduces per-call thread spawns to zero (see Rationale), so the issue's
   "pooled overhead materially closer to `Native.parse`" criterion targets
   the pure queue-handoff cost: a `Queue#push` onto the job queue plus a
   condvar-wakeup and `Queue#pop` on the reply queue, with no `Thread.new` at
   all on the call path. This should approach `Native.parse`'s own cost far
   more closely than today's per-call `Thread.new`. Targets in
   [benchmark-methodology "Concrete target"](../research/benchmark-methodology/README.md#concrete-target-for-a-pooled-dispatch-scenario)
   (`empty` scenario: `Native.parse` ~13.6–16.6µs/call; today's `Thread.new`
   adds ~70–180µs; a pool should approach the low-single-digit-µs queue-
   handoff cost, not the thread-spawn cost).

2. **Configurable pool size** — a test asserting the worker count is
   settable (env var, e.g. `DUCKLING_POOL_SIZE`, and/or an explicit
   `Duckling::Pool.start(size:)` call) and defaults sanely. Resolve *when*
   size is resolved (env read at `require` time vs. lazy) before writing this
   test, since it interacts with step 4's leak-detection baseline
   ([hand-rolled-pool §5](../research/hand-rolled-pool/README.md#5-configurable-pool-size)).

3. **GC-safety boundary unchanged** — no new test needed here *if* the
   pool's job/reply channel is built like `ParsePayload` already is: only
   plain owned Ruby objects (`String`, `Time`, `Array`, `Hash`, `Exception`)
   crossing the queue, nothing from inside `Native.parse`'s Rust layer.
   Confirm this as an explicit design constraint, and rerun
   `test/duckling_gc_stress_test.rb` (`GC.stress = true`) with the pool
   wired in as a regression check, since it already exercises the
   highest GC-pressure path in the repo.

4. **Clean shutdown / no leaked threads** — needs an explicit
   `shutdown!`-equivalent method (poison-pill sentinel per worker + `join`),
   not reliance on `auto_terminate`/daemon-thread status alone, since "no
   leaked threads across the test suite" cares about `Thread.list` staying
   clean *between* tests, not just about the process eventually exiting
   ([hand-rolled-pool §4](../research/hand-rolled-pool/README.md#4-clean-shutdown-across-minitest--process-exit)).
   Add a `Thread.list`-diff test (snapshot before pool startup, assert equal
   after `shutdown!` + `join` return) alongside
   `test/thread_pool_dispatch_test.rb`'s existing `SpawnCounter` technique,
   exercising pool lifecycle rather than per-call spawn counting. Resolve
   eager-vs-lazy pool startup first — it changes where the `Thread.list`
   baseline is captured and whether the no-`Fiber.scheduler` test path ever
   starts the pool. Register an `at_exit` shutdown as a process-exit
   backstop only — it cannot substitute for explicit per-test-run shutdown
   (fires once, at real interpreter shutdown).

5. **Keep `test/falcon_fiber_blocking_test.rb` passing** — the calling Fiber
   blocks directly on the per-call reply `Queue#pop`, which is
   scheduler-hooked (verified — see the crux), so the reactor keeps running
   while it waits, with no per-call `Thread.new`. No change to this test's
   assertions should be needed; it's a regression gate on the dispatch
   mechanism, not the pool internals. Consider adding a companion assertion
   (or extending `test/thread_pool_dispatch_test.rb`'s `SpawnCounter`) that
   the Fiber-scheduler path spawns **zero** per-call threads, pinning the new
   floor this design achieves — it's the concrete acceptance signal for the
   whole issue.

6. **Keep `test/thread_pool_dispatch_test.rb` passing** — this test only
   exercises the no-`Fiber.scheduler` branch, which today calls
   `Native.parse` directly with zero thread spawns and stays untouched by a
   pool that only replaces the Fiber-scheduler branch's dispatch. Confirm
   pool-worker creation (step 2) happens at pool-startup, not per-call, so
   `SpawnCounter`'s instrumentation (which counts `Thread.new` calls made
   *during* a timed `Duckling.parse` call) isn't tripped by workers already
   running before the timed calls happen.

7. **Benchmark comparison** — wire a pooled-dispatch data point into
   `bin/benchmark` per
   [benchmark-methodology "New territory"](../research/benchmark-methodology/README.md#new-territory).
   Recommend **Option B** (reuse the existing schema, compare recordings
   across versions) over Option A, since Option A requires keeping the
   pre-pool `Thread.new` path independently reachable purely for
   benchmarking (extra surface area this gem doesn't otherwise want once the
   pool ships), while Option B needs zero `report.rb`/schema changes and the
   "before" data (`0.3.0-rc1.json` per environment) is already committed.
   Trade-off to accept: cross-version rather than same-run comparison,
   subject to the ~20–30% environment-noise swing `docs/benchmarks/README.md`
   already documents as normal.

## Open questions

Two questions this plan previously left open are now **resolved** by a
direct spike, and their answers are baked into the Decision above:
`Queue#pop`/`Mutex#lock`/`ConditionVariable#wait` on the calling Fiber
cooperate with `Fiber.scheduler` (so the pool needs no per-call wait-wrapper
thread — zero per-call spawns), and `concurrent-ruby`'s `Future#value`
cooperates too (so both pool options reach that same floor). See the crux
and the two research docs' empirical-verification sections. What remains
open:

- **The Ruby 3.4+ nuance flagged in `current-dispatch-terrain`**: a later
  spike (commit `875a840`, migrated off-repo) suggested `rb_nogvl` +
  `RB_NOGVL_OFFLOAD_SAFE` might obviate the `Thread` wrapper entirely on
  Ruby 3.4+, narrower than the general "bare GVL release never unblocks a
  Fiber" statement this design rests on
  ([current-dispatch-terrain §3](../research/current-dispatch-terrain/README.md#3-why-a-bare-gvl-release-doesnt-unblock-an-asyncreactor-fiber)).
  If true and adoptable, a bare `Native.parse` GVL release would unblock the
  calling Fiber on its own — removing the need for the Fiber-scheduler
  dispatch branch (and therefore the pool itself) on Ruby 3.4+, independent
  of this work. Worth flagging to the eventual implementer, since it could
  make the whole pool a 3.3-only concern for newer Rubies.
- **Eager vs. lazy pool startup** — not resolved by either research doc;
  affects the `Thread.list` leak-test baseline (step 4) and whether the
  no-scheduler test path ever starts the pool.
- **Exact benchmark wiring mechanics for step 7** — `parse_benchmark.rb`'s
  `run_ips` would need the pooled dispatch path reachable under `Sync`
  (mirroring how `Duckling.parse` is measured today); the precise
  `report.rb` diff (if Option A is ever revisited) isn't sketched here.
