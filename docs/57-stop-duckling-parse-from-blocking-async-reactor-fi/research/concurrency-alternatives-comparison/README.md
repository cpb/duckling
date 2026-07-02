# Concurrency Alternatives Comparison

Research terrain map for issue [#57](https://github.com/cpb/duckling/issues/57)
answering: once `Duckling.parse` stops holding the GVL for the duration of
its native call, **what dispatches the call so it actually runs
concurrently with the calling Fiber's sibling Fibers**, and which dispatch
strategy should this gem ship first?

## Provisional dependency on `fiber-scheduler-mechanism-spike`

This document was written before the sibling research topic
`fiber-scheduler-mechanism-spike` had produced output in this worktree (its
doc lives at
`docs/57-stop-duckling-parse-from-blocking-async-reactor-fi/research/fiber-scheduler-mechanism-spike/README.md`
once merged, in a different agent's isolated worktree — not visible here).
Everything below rests on that topic's **working hypothesis**, treated as
provisional pending its empirical results:

> Releasing the GVL alone (e.g. a raw `rb_thread_call_without_gvl` callback
> invoked on the calling Fiber's own OS thread) is not sufficient. This
> gem's Ruby floor is `>= 3.2.0`
> ([`duckling.gemspec#L15`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/duckling.gemspec#L15)),
> and CI currently tests `3.3.6`
> ([`.github/workflows/main.yml`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/.github/workflows/main.yml)),
> both below Ruby 3.4. `Fiber::Scheduler#blocking_operation_wait` — the
> hook a 3.4+ VM uses to let a scheduler run a GVL-released blocking
> operation without stalling sibling fibers on the same OS thread — does
> not exist in the [3.3 `Fiber::Scheduler` hook list](https://docs.ruby-lang.org/en/3.3/Fiber/Scheduler.html)
> and is present in [3.4's](https://docs.ruby-lang.org/en/3.4/Fiber/Scheduler.html).
> Confirmed directly against both doc pages while writing this document.
> Without that hook, a GVL release on the calling thread doesn't hand
> control back to the reactor's fiber scheduler — the OS thread is still
> physically busy running Rust code either way, so sibling Fibers
> cooperatively scheduled on that same OS thread still don't run. **The fix
> therefore likely needs to dispatch each `Duckling.parse` call onto a
> genuine background OS thread** (with the GVL released inside the native
> call on that background thread), not just release the GVL in place.

If `fiber-scheduler-mechanism-spike` lands with a different conclusion —
e.g. that a bare GVL release turns out to be enough on this gem's supported
Ruby versions for some other reason — this document's comparison of *how*
to dispatch onto a thread becomes moot and should be revisited.

## Where today's implementation stands

`ext/duckling/src/lib.rs`'s `parse` function
([current implementation](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/ext/duckling/src/lib.rs#L25-L63))
calls `duckling::parse` directly on whatever thread invoked the Magnus
method — no GVL release, no thread dispatch. The repo's own
`benchmark-ips` suite (issue [#59](https://github.com/cpb/duckling/issues/59))
already captured what that costs under concurrency: 10 Ruby threads calling
`Duckling.parse` today reach only **10.1% of ideal linear scaling** (1661
ops/sec measured vs. 1643.7 ops/sec single-threaded) — see the
`concurrency` block in
[`docs/benchmarks/local/0.2.0.json`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/docs/benchmarks/local/0.2.0.json).
That's the GVL doing exactly what it's designed to do: serializing every
call. Whatever dispatch strategy issue #57 lands on needs to actually
unlock concurrency once the GVL is released for the call itself — a
dispatch strategy that still serializes all callers behind one worker
would leave that number close to where it is today.

The same benchmark file gives per-call latency by scenario, which grounds
the "is thread-spawn overhead worth worrying about" question below:

| Scenario | µs/call |
|---|---|
| `empty` | 24.1 |
| `no_match` | 213.4 |
| `short` | 678.3 |
| `medium` | 690.5 |
| `long` | 3772.4 |
| `camping_trip_email` (pathological) | 791,063.3 |

## Comparison

| | [Thread-per-call](./thread-per-call.md) | [Worker-pool](./worker-pool.md) | Process isolation |
|---|---|---|---|
| Spawn cost per call | ~1 OS thread create/teardown (tens of µs, measured below) | ~0 (thread already running); queue push/pop only | Full IPC round-trip + serialization |
| Concurrency ceiling | Bounded only by the OS and the wrapped crate's own thread-safety | Bounded by pool size (1 worker = fully serialized) | Bounded by process count |
| Implementation complexity | Low — one `Thread.new { ... }.value` per call | Medium — queue(s), result correlation, worker lifecycle, shutdown | High — process management, wire protocol |
| Panic/exception propagation | Free, via `Thread#value` re-raise semantics | Manual — must rescue in the worker loop and repost | Must reconstruct across a serialization boundary |
| Fits issue #57's scope (no throughput optimization) | Yes | Partially — adds complexity in service of a goal that's out of scope | No |

Full analysis: [Thread-Per-Call Dispatch](./thread-per-call.md),
[Persistent Worker-Pool Dispatch](./worker-pool.md).

### Why not process isolation

Issue #57 explicitly scopes out "general parse-throughput optimization
beyond removing the reactor-blocking behavior." Process isolation (a
separate worker process, results serialized over a pipe or socket as JSON
or similar) doesn't just fail to help with that non-goal — it actively
works against the reason this gem exists at all. Per `AGENTS.md`'s framing,
`duckling` wraps [duckling](https://github.com/wafer-inc/duckling) via
Magnus "so Ruby code can extract entities ... without running a separate
HTTP service." A local pipe/socket to a sibling process is a smaller
version of the exact cost (serialize request, cross a process boundary,
deserialize response, deserialize `Entity` results back into Ruby objects)
that embedding a Rust NER engine in-process was chosen specifically to
avoid. Given the benchmark table above shows most real calls complete in
well under a millisecond, adding IPC/serialization overhead of a
comparable or larger magnitude for every call would be a regression
disguised as a fix. Not investigated further here.

## Recommendation

**Thread-per-call.** Rationale:

1. **No throughput-optimization goal is in scope for issue #57** — the
   acceptance criteria are about not blocking sibling Fibers and preserving
   `catch_unwind` panic-safety, not about maximizing calls/sec. Thread-per-call
   satisfies both directly: every call gets its own OS thread, so it can
   never be head-of-line blocked behind another in-flight `Duckling.parse`
   call the way a single-worker pool would serialize concurrent callers.
2. **Measured spawn overhead is small relative to real call costs, and
   the worst case (a pathological, `out_of_scope` input like
   `camping_trip_email` at 791ms) makes spawn overhead a rounding error.**
   Measured locally on this machine (Ruby 3.3.6, `Thread.new{}.join` in a
   tight loop, 2000 iterations): ~70µs/thread average. That's real
   overhead relative to the fastest scenarios (`empty` at 24.1µs, `no_match`
   at 213.4µs) — plausibly doubling or tripling wall-clock latency on those
   — but negligible against `short`/`medium` (~680-690µs, roughly 10%
   overhead) and vanishing against `long` (3.8ms) or the pathological case.
   Given issue #57's explicit non-goal of throughput optimization, this
   tradeoff (worse constant-factor latency on the fastest inputs, in
   exchange for correctness and simplicity) is the right one to accept now.
3. **Panic-safety composes for free.** As detailed in
   [Thread-Per-Call Dispatch](./thread-per-call.md), a panic that reaches
   Magnus's own FFI dispatch boundary is already converted to a raised
   Ruby exception by Magnus itself, on whichever thread is executing the
   call — regardless of whether that's the main thread or a
   `Thread.new`-spawned one. `Thread#value`'s standard re-raise semantics
   then carry that exception back to the caller with no bespoke code. A
   worker-pool needs to hand-roll this (rescue in the worker loop, repost
   the exception object across the response queue, re-raise it in the
   caller's context).
4. **Simplicity matches the codebase's current size.** This gem has one
   public method. A persistent worker pool's lifecycle questions (start
   eagerly at `require` time or lazily on first call? clean shutdown via
   `at_exit`? what happens to in-flight work if the process exits mid-call?)
   are real design surface that thread-per-call sidesteps entirely — there
   is no persistent state to manage, so there is nothing to get wrong.

A worker-pool is legitimate **future optimization work** if per-call spawn
overhead is ever shown to matter in practice (e.g. a production workload
dominated by many back-to-back `empty`/`no_match`-shaped calls where the
~70µs/call floor becomes a measurable fraction of total latency) — but
that's throughput optimization, explicitly out of scope for issue #57.
Building it now would be solving a problem this issue doesn't have yet, at
the cost of correctness-relevant complexity (queue management, result
correlation, lifecycle) that the simpler approach avoids.

## Open follow-ups

- The ~70µs/thread figure above is a local, single-machine measurement
  (`Thread.new{}.join` in a tight loop on this sandbox's Ruby 3.3.6), not a
  guarantee for every deployment target — CI runners and production hosts
  will differ. It's cited here as an order-of-magnitude sanity check
  against the benchmark-ips scenario latencies, not as a portable constant.
  If thread-per-call ships and a worker-pool is ever revisited, re-measure
  on the actual target environment rather than reusing this number.
- Neither dispatch strategy has been prototyped against
  `test/falcon_fiber_blocking_test.rb` (referenced in issue #57 as an
  existing failing hill test on this branch) — this document reasons about
  dispatch strategy in the abstract; the actual fix still needs to be
  implemented and run against that test.
- This document assumes the working hypothesis above (bare GVL release is
  insufficient on Ruby 3.2/3.3) holds. If `fiber-scheduler-mechanism-spike`
  empirically contradicts it, revisit whether thread dispatch is needed at
  all before implementing either strategy here.
- Not investigated: whether a *bounded* worker pool (more than 1 thread,
  but fewer than "one per call") could capture most of thread-per-call's
  concurrency while amortizing spawn cost — this document only compared
  the two endpoints (1 vs. unbounded) named in the issue's framing. Worth a
  look if a future throughput-optimization pass ever gets scoped in.
