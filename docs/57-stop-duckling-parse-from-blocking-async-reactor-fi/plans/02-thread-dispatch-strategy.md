# Thread Dispatch Strategy for `Duckling.parse`

Plan doc for issue #57, scoped specifically to **the dispatch-strategy
decision and its downstream implications** — given that a background
`Thread` must exist per the empirical finding in
[Fiber-Scheduler Mechanism Spike](../research/fiber-scheduler-mechanism-spike/README.md),
*how* should `Duckling.parse` dispatch onto one, and what does that commit
this gem to going forward? The concrete Rust/Ruby shape of the GVL-release
change itself (what code changes where in `ext/duckling/src/lib.rs`) is
covered by the sibling plan doc, `./01-gvl-release-implementation.md` — this
document does not duplicate it.

## Decision

**Adopt thread-per-call** (`Thread.new { native_call }.value`, one brand-new
OS thread per `Duckling.parse` invocation, no persistent worker state) as
recommended in
[Concurrency Alternatives Comparison](../research/concurrency-alternatives-comparison/README.md).

Having read that comparison in full alongside the other four research docs,
**I concur.** Nothing in the underlying research changes the calculus laid
out there — if anything, the empirical result in
[Fiber-Scheduler Mechanism Spike](../research/fiber-scheduler-mechanism-spike/README.md)
(a genuine background `Thread` is *required*, not merely one option among
several equally-valid ones) makes the "how to dispatch onto a thread"
question sharper, not more open: some thread-spawning mechanism is
mandatory, so the remaining question really is just thread-per-call vs.
worker-pool vs. process isolation, which the comparison doc already
resolves convincingly against issue #57's own stated scope.

## Rationale

1. **No throughput-optimization goal is in scope for issue #57.** The
   acceptance bar is "sibling Fibers don't stall," not "calls/sec is
   maximized." Thread-per-call satisfies the former directly — every call
   gets an independent OS thread, so no caller is ever head-of-line-blocked
   behind another in-flight `Duckling.parse` call, unlike a single-worker
   pool.
2. **Panic/exception propagation is free.** [duckling](https://github.com/wafer-inc/duckling)'s
   own `catch_unwind` layers plus Magnus's outer `catch_unwind` (both
   detailed in
   [Thread-Per-Call Dispatch](../research/concurrency-alternatives-comparison/thread-per-call.md#interaction-with-catch_unwind-panic-safety))
   mean a panic anywhere in the call graph is already an ordinary raised
   Ruby exception by the time it would reach a spawned thread's block
   boundary. `Thread#value`'s documented re-raise semantics then carry it to
   the caller with zero bespoke code. The worker-pool alternative needs a
   hand-rolled `rescue`/repost-via-response-queue path in its worker loop —
   a real correctness risk (a missed exception class permanently wedges
   that worker with no caller ever finding out beyond a hung `Queue#pop`).
3. **Spawn overhead is small relative to real call costs.** Measured
   locally (Ruby 3.3.6, `Thread.new{}.join` in a tight loop, 2000
   iterations): ~70µs/thread average
   ([Thread-Per-Call Dispatch](../research/concurrency-alternatives-comparison/thread-per-call.md#os-thread-creationteardown-cost)).
   Set against the repo's own `benchmark-ips` scenario latencies
   ([`docs/benchmarks/local/0.2.0.json`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/docs/benchmarks/local/0.2.0.json)):
   negligible-to-10% overhead on `short`/`medium` inputs (~680-690µs) and a
   rounding error against `long` (3.8ms) or the pathological
   `camping_trip_email` case (791ms). It's only proportionally large against
   the fastest inputs (`empty` 24.1µs, `no_match` 213.4µs) — see the next
   section for why that specific case matters for the dispatch-strategy
   question, not just the strategy comparison itself.
4. **Simplicity matches the codebase's current size.** A worker-pool's
   lifecycle questions (eager vs. lazy start, `fork` safety, `at_exit`
   shutdown) are real design surface a one-public-method gem doesn't need to
   take on. Thread-per-call has no persistent state, so there is nothing
   there to get wrong.

## What adopting thread-per-call commits this gem to

The decision above answers "what mechanism, when a thread is spawned" — but
research left open whether a thread should be spawned **unconditionally on
every call**, including calls made from a plain synchronous context with no
async reactor to protect (a single-threaded CLI script, a Puma worker
running in threaded-but-not-fiber-scheduled mode, an ordinary Rails request).
In that context, spawning a thread buys nothing — there are no sibling
Fibers being starved — and the ~70µs + ~2MB overhead
([Thread-Per-Call Dispatch](../research/concurrency-alternatives-comparison/thread-per-call.md#os-thread-creationteardown-cost))
is pure cost, proportionally largest on exactly the `empty`/`no_match`-shaped
calls flagged above.

Two designs were considered:

- **A: unconditional spawn, no opt-out.** Every `Duckling.parse` call always
  spawns a `Thread`, regardless of context. Simplest possible implementation
  and test surface; identical behavior everywhere.
- **B: detect "is a reactor even present" and skip the spawn when not.**
  Either (b1) a caller-supplied kwarg such as `async: false`, or (b2)
  runtime auto-detection via `Fiber.current_scheduler`.

### Is `Fiber.current_scheduler` a sound detection signal?

Checked directly against Ruby core docs
([`Fiber.current_scheduler`](https://docs.ruby-lang.org/en/3.3/Fiber.html#method-c-current_scheduler)):

> Returns the Fiber scheduler, that was last set for the current thread with
> `Fiber.set_scheduler` if and only if the current fiber is non-blocking.

This is a real subtlety, not a clean "nil means no reactor" signal:
`current_scheduler` returns `nil` in **two** distinct situations — (a) no
scheduler was ever set on the current thread (no reactor at all, the
synchronous case this check is meant to catch), and (b) a scheduler *is*
set, but the currently-running Fiber is a **blocking** one (per the same
page, a Fiber's blocking-vs-non-blocking status is fixed at
`Fiber.new(blocking: ...)`/`Fiber.schedule` time). Case (b) matters here
because, per the same doc's description of blocking fibers, a blocking
Fiber's blocking operations suspend the whole thread rather than invoking
scheduler hooks — which is exactly the behavior `Thread#value`'s
`block`/`unblock` hooks rely on to let the calling Fiber yield (see
[Fiber-Scheduler Mechanism Spike](../research/fiber-scheduler-mechanism-spike/README.md#mechanism-explanation-blockunblock-vs-blocking_operation_wait)).
In other words: in case (b), spawning a background `Thread` and calling
`#value` on it **would not have helped anyway** — a blocking Fiber's
`Thread#join` doesn't yield to the scheduler regardless. So `nil` from
`current_scheduler` correctly identifies "spawning a thread here provides no
protection" in both of its two underlying cases, not just the first. This
makes b2 a sound signal for the specific decision "should I pay spawn
overhead," though it has not been exercised against
`test/falcon_fiber_blocking_test.rb` or any equivalent "verify skip-path
still behaves" test — see Open Questions.

### Recommendation: ship design A (unconditional spawn) for the initial fix

Despite b2 being sound, this plan recommends **not** building either opt-out
path as part of issue #57:

- Adding *any* conditional branch here is itself a latency/throughput
  optimization for the non-reactor case — the same category of goal
  [Concurrency Alternatives Comparison](../research/concurrency-alternatives-comparison/README.md)
  cites as explicitly out of scope when rejecting the worker-pool
  alternative ("adds complexity in service of a goal that's out of scope").
  The reasoning applies symmetrically here.
- A caller-supplied `async: false` kwarg (design b1) pushes a
  context-detection burden onto every caller of a one-method gem, with no
  enforcement if they get it wrong (forgetting `async: false` in a
  synchronous hot loop reintroduces the exact overhead this option is meant
  to avoid; passing it incorrectly inside a real reactor reintroduces the
  original bug). Auto-detection (b2) is strictly preferable to a kwarg *if*
  either is ever built, since it needs no caller cooperation and can't be
  passed incorrectly.
- The codebase's own stated preference (echoed throughout the
  worker-pool-rejection rationale) is that a small, single-method gem
  benefits from having "nothing to get wrong" — an unconditional spawn keeps
  `Duckling.parse` at one code path, one behavior, everywhere, which is
  easier to reason about and to keep passing
  `test/falcon_fiber_blocking_test.rb` against as the gem evolves.

If the ~70µs/call floor is ever shown to matter in a real workload dominated
by fast (`empty`/`no_match`-shaped) calls in a non-reactor context, revisit
design b2 as a **scoped, additive** follow-up — the soundness analysis above
is already done, so that future work would start from "add the check and
its test," not from re-litigating whether the signal is trustworthy.

## Open questions

- **`Fiber.current_scheduler`'s b2 detection has not been exercised in a
  test.** The soundness argument above is doc-and-source reasoning, not an
  empirical run (unlike the rest of this issue's research, which is
  empirical throughout). If design b2 is ever picked up, it needs its own
  spike analogous to
  [Fiber-Scheduler Mechanism Spike](../research/fiber-scheduler-mechanism-spike/README.md),
  not just this document's reasoning.
- **Revisit if `duckling` throughput at scale ever becomes a real
  bottleneck under thread-per-call's per-call overhead.** Out of scope for
  issue #57 per its own scope note, but worth recording as the concrete
  trigger condition for reconsidering a worker-pool
  ([Persistent Worker-Pool Dispatch](../research/concurrency-alternatives-comparison/worker-pool.md)) —
  specifically, a production workload dominated by many back-to-back
  `empty`/`no_match`-shaped calls where the ~70µs/call floor becomes a
  measurable fraction of total latency.
- **Revisit if the Ruby floor is ever bumped to 3.4+.** Not proposed here —
  staying on the current `>= 3.2.0` floor
  ([`duckling.gemspec#L15`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/duckling.gemspec#L15))
  is an explicit decision outside this document's scope. But
  [Fiber-Scheduler Mechanism Spike](../research/fiber-scheduler-mechanism-spike/README.md#conclusion)
  notes `Fiber::Scheduler#blocking_operation_wait` (3.4+) would only change
  this calculus if the native code additionally called the lower-level
  `rb_nogvl` with `RB_NOGVL_OFFLOAD_SAFE` set — a separate, later decision.
  If that ever happens, it's worth re-examining whether `async`'s own
  worker-pool auto-offload could replace this gem's own thread-per-call
  dispatch entirely (letting the VM/scheduler manage the thread instead of
  the gem) — flagged here purely as a future trigger condition, not a
  proposal to act on now.
- **Bounded worker pools (N > 1, N < unbounded) remain uninvestigated**, per
  [Concurrency Alternatives Comparison](../research/concurrency-alternatives-comparison/README.md#open-follow-ups) —
  this document inherits that gap rather than closing it, since it's
  squarely a throughput-optimization question out of scope for issue #57.
