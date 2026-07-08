# Plan: pool design recommendation for issue #71

Terrain for the future `/hill-first` test-writing session, not something to
implement directly from this PR (issue #71 is labeled `test-first`).

## Decision

Build a **hand-rolled, stdlib-only `Queue`-based worker pool** in-repo
(`Duckling::Pool` or similar), not `concurrent-ruby`. Do not adopt any other
standalone thread-pool gem — none is a live candidate (see Rationale).

**Flagged for operator review:** the crux argument below rests on "pooling
cannot reduce per-call `Thread.new` to zero," which a later spike
([hand-rolled-pool's empirical verification](../research/hand-rolled-pool/README.md#empirical-verification-bare-queuepopmutexlockconditionvariablewait-are-fiber-scheduler-hooked))
found to be false: a bare `Queue#pop` on the calling Fiber already
cooperates with `Fiber.scheduler`, so the per-call wait-wrapper thread this
Decision assumes as an unavoidable floor is not actually needed. This
doesn't automatically flip the hand-rolled-vs-`concurrent-ruby` choice
(both approaches turn out to reach zero per-call threads, not just
hand-rolled), but it removes the specific asymmetry this Decision was
based on — see Open Questions.

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
This is the deciding factor, and it points toward hand-rolled for a reason
distinct from dependency count: **neither option is known to eliminate the
per-call thread spawn**, and hand-rolled's version of that limitation is
better-understood than `concurrent-ruby`'s.

- The hand-rolled research doc **proves** (not speculates) that a pure
  `Queue#pop`-based wait does not cooperate with `Fiber.scheduler` — only
  `Thread#join`/`Thread#value`/`Mutex#lock` and a few other specific
  primitives are scheduler-hooked. A calling Fiber can never call
  `reply_queue.pop` directly on the reactor's OS thread without stalling the
  whole reactor (the exact bug issue #64 fixed). The workaround the doc's
  sketch uses — `Thread.new { reply.pop }.value` — still spawns **one**
  thread per call, just a thin wait-wrapper instead of a thread that also
  runs `Native.parse`. Pooling only removes the *second* thread (the one
  that ran the native call), not thread-spawn overhead entirely
  ([hand-rolled-pool §3](../research/hand-rolled-pool/README.md#3-pseudocode-sketch-illustrative--not-production-code)).
- `concurrent-ruby`'s `Future#value` is claimed to block "via the same kind
  of Ruby-level thread/Fiber interaction (`Thread#value`-equivalent unblock
  hooks)" the Falcon test depends on — but the research doc **explicitly
  flags this as untested**: "this claim is untested here; this research task
  did not run the suite against a prototype, so it's a hypothesis, not a
  verified result"
  ([concurrent-ruby-executors, comparison table](../research/concurrent-ruby-executors/README.md#comparison-against-issue-71s-constraints),
  row "`test/falcon_fiber_blocking_test.rb` keeps passing").

`concurrent-ruby` cannot currently promise anything the hand-rolled approach
can't, and carries strictly more unknowns: a new runtime dependency (this gem
has exactly one today, `rb_sys`, called out in `AGENTS.md`'s "Known gotchas"
as needed even for precompiled consumers) plus an unverified assumption about
`Future#value`'s scheduler-cooperation that would need spiking before
trusting it. Hand-rolled's ceiling (one thread per call, for the
wait-wrapper) is mechanically understood, derived from the same
block/unblock-hook reasoning already proven correct for today's
`Thread.new{...}.value`. Recommend building the pool in-repo and treating
"does pooling reduce per-call `Thread.new` to zero" as a **closed, negative**
question — see Open Questions for what would change this.

## Steps

For the eventual `/hill-first` test-writing session and later implementation,
tied to issue #71's acceptance criteria:

1. **Pin the realistic acceptance bar before writing tests.** Since pooling
   cannot reduce per-call thread spawns to zero (see Rationale), confirm the
   issue's "pooled overhead materially closer to `Native.parse`" criterion
   against a concrete number: the wait-wrapper `Thread.new` cost plus a
   `Queue#push`/`Queue#pop`/condvar-wakeup handoff, not the
   `Native.parse`-call-inside-the-thread cost this design removes. Targets in
   [benchmark-methodology "Concrete target"](../research/benchmark-methodology/README.md#concrete-target-for-a-pooled-dispatch-scenario)
   (`empty` scenario: `Native.parse` ~13.6–16.6µs/call; today's `Thread.new`
   adds ~70–180µs; a pool should approach the queue-handoff cost, not zero).

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

5. **Keep `test/falcon_fiber_blocking_test.rb` passing** — the pool's
   per-call dispatch must still route the calling Fiber's wait through a
   `Thread#value`/`Thread#join`-shaped primitive (per step-1's finding, this
   remains a thin per-call `Thread.new { reply.pop }.value` wrapper, not a
   direct `reply.pop`). No change to this test's assertions should be
   needed; it's a regression gate on the dispatch mechanism, not the pool
   internals.

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

- **`Future#value`'s Fiber-scheduler cooperation — resolved, confirmed.**
  Spiked and verified: `Future#value` does cooperate with
  `Fiber.scheduler` (transitively, via the `Mutex`/`ConditionVariable` its
  `Concurrent::Event` wait is built on)
  ([concurrent-ruby-executors, empirical verification](../research/concurrent-ruby-executors/README.md#empirical-verification-does-futurevalue-cooperate-with-fiberscheduler)).
- **Whether a queue-native `Fiber::Scheduler` hook exists that could avoid
  the per-call wait-wrapper thread entirely — resolved, confirmed yes.**
  Spiked directly: a bare `Queue#pop`/`Mutex#lock`/`ConditionVariable#wait`
  called on the calling Fiber's own thread (no `Thread.new` wrapper at all)
  already yields to the `Async::Reactor`
  ([hand-rolled-pool, empirical verification](../research/hand-rolled-pool/README.md#empirical-verification-bare-queuepopmutexlockconditionvariablewait-are-fiber-scheduler-hooked)).
  This overturns the "one thread per call is the floor" conclusion the
  Decision above was based on — the per-call wait-wrapper thread in step 5
  and the pseudocode sketch may not be needed at all, for either a
  hand-rolled or `concurrent-ruby`-backed pool. **Needs operator input**:
  does this change the Decision, and if the wait-wrapper thread is dropped,
  does step 1's benchmark target change too (the pool could then approach
  `Native.parse`'s own cost directly, not "queue-handoff cost plus one
  thread spawn")?
- **The Ruby 3.4+ nuance flagged in `current-dispatch-terrain`**: a later
  spike (commit `875a840`, migrated off-repo) suggested `rb_nogvl` +
  `RB_NOGVL_OFFLOAD_SAFE` might obviate the `Thread` wrapper entirely on
  Ruby 3.4+, narrower than the general "bare GVL release never unblocks a
  Fiber" statement this design rests on
  ([current-dispatch-terrain §3](../research/current-dispatch-terrain/README.md#3-why-a-bare-gvl-release-doesnt-unblock-an-asyncreactor-fiber)).
  If true and adoptable, it could remove the per-call thread-wrapper
  question entirely for Ruby 3.4+, independent of pooling — worth flagging
  to the eventual implementer, since it could change step 5 for newer Rubies.
- **Eager vs. lazy pool startup** — not resolved by either research doc;
  affects the `Thread.list` leak-test baseline (step 4) and whether the
  no-scheduler test path ever starts the pool.
- **Exact benchmark wiring mechanics for step 7** — `parse_benchmark.rb`'s
  `run_ips` would need the pooled dispatch path reachable under `Sync`
  (mirroring how `Duckling.parse` is measured today); the precise
  `report.rb` diff (if Option A is ever revisited) isn't sketched here.
