# Persistent Worker-Pool Dispatch

One (or a small fixed number of) long-lived background Ruby `Thread`(s)
pull work off a queue, run `Duckling.parse`, and post results back. No new
gem dependency needed — plain
[`Thread::Queue`](https://docs.ruby-lang.org/en/3.3/Thread/Queue.html)
(stdlib `thread`, always loaded) is sufficient to sketch a request/response
pattern:

```ruby
module Duckling
  REQUESTS  = Queue.new
  Job = Struct.new(:args, :kwargs, :response)

  WORKER = Thread.new do
    loop do
      job = REQUESTS.pop
      break if job == :shutdown
      begin
        job.response.push([:ok, parse_native(*job.args, **job.kwargs)])
      rescue => e
        job.response.push([:error, e])
      end
    end
  end

  def self.parse(*args, **kwargs)
    response = Queue.new
    REQUESTS.push(Job.new(args, kwargs, response))
    status, value = response.pop
    status == :ok ? value : raise(value)
  end
end
```

This sketch is illustrative, not a proposal to implement — see the parent
README's recommendation for why thread-per-call is the better starting
point.

## Avoided cost: no per-call thread spawn

The pool's worker thread(s) already exist by the time a call arrives, so
each `Duckling.parse` call pays only a `Queue#push` + `Queue#pop` round
trip (a mutex-protected, condition-variable-based handoff — see
[`Thread::Queue`](https://docs.ruby-lang.org/en/3.3/Thread/Queue.html)),
not the ~70µs OS-thread create/teardown cost measured in
[Thread-Per-Call Dispatch](./thread-per-call.md). For the fastest
benchmark scenarios (`empty` at 24.1µs) this avoids what would otherwise be
a 2-4x latency multiplier from spawn overhead alone.

## Added complexity

### Queue management and result correlation

The sketch above uses a *response queue per call* (`response = Queue.new`)
to correlate each request with its answer without a shared mutable
"results" map — the calling Fiber blocks on its own private queue, and the
worker pushes exactly one item to it. This avoids needing request IDs or a
shared results hash guarded by its own mutex, but it does mean allocating a
`Queue` object per call (cheap relative to a `Thread`, but not free) and
getting the rescue/repost logic right in the worker loop.

### Worker lifecycle

Two decisions with real tradeoffs, neither obviously right:

- **Start eagerly at `require "duckling"` time**, inside `lib/duckling.rb`:
  simple, predictable, but spawns a thread (and reserves its ~2MB stack —
  see [Thread-Per-Call Dispatch](./thread-per-call.md)'s stack-size figures)
  for every process that merely requires the gem, even if it never calls
  `Duckling.parse`. Also complicates any process that `fork`s after
  `require` (e.g. Unicorn/Puma cluster mode, `Process.fork` in tests) —
  threads do not survive `fork` in the child process, so a naively-started
  worker thread would need to be re-spawned post-fork, which requires the
  gem to hook `Process._fork` or document the caveat.
  - **Note:** thread-per-call has no equivalent problem — there's no
    persistent thread to lose across a fork, since nothing exists between
    calls.
- **Start lazily on first `Duckling.parse` call**: avoids the
  always-pay-the-cost problem, but needs thread-safe
  once-only-initialization (a `Mutex`-guarded lazy `WORKER ||= Thread.new
  { ... }`, or `Ractor`-unsafe-but-fine-here class-level memoization) —
  more code, more room for a race on first concurrent access from multiple
  Fibers before the worker exists yet.

### Clean shutdown

A long-lived thread needs an explicit shutdown path or it keeps the
process alive / gets killed abruptly at interpreter exit. `at_exit { REQUESTS.push(:shutdown); WORKER.join }`-style
cleanup is the standard pattern, but it's more moving parts than
thread-per-call has (which needs no shutdown hook at all — nothing
outlives any individual call).

## Serialization bottleneck under concurrent load

This is the sharpest tradeoff against thread-per-call. A single-worker
pool means **concurrent callers queue up rather than truly parallelizing**:
if Fiber A's `Duckling.parse` call is mid-flight on the one worker thread,
Fiber B's call sits in `REQUESTS` until A's finishes, even though the
[sibling `duckling-crate-thread-safety` research](../duckling-crate-thread-safety/README.md)
confirms the wrapped [duckling](https://github.com/wafer-inc/duckling)
crate itself has no obstacle to running multiple calls fully concurrently
(no unsynchronized global state; every cross-thread type is `Send + Sync`
by construction). A 1-worker pool would throw away exactly the concurrency
headroom that crate-level analysis says is available — worse than doing
nothing architecturally clever at all, since it adds queue-handoff latency
on top of not parallelizing.

A pool sized at N > 1 workers mitigates this but reintroduces a sizing
question with no obviously-right default (N = number of reactor fibers
expected concurrently? A fixed small constant? Configurable by the
caller?) — more design surface, again in service of a throughput/
concurrency-headroom goal that issue #57 explicitly scopes out
("General parse-throughput optimization beyond removing the
reactor-blocking behavior" is out of scope).

## Panic/exception propagation is not free

Unlike thread-per-call, there is no `Thread#value` call sitting between
the caller and the worker thread — the worker thread never exits (that's
the whole point of it being persistent), so there's no natural `#join`
point for a raised exception to be re-raised through automatically. The
sketch above handles this manually: the worker's `rescue => e` catches
whatever exception surfaces (whether an ordinary `Err(Error)` from
`duckling::parse` returning invalid input, or a panic already converted to
a Ruby exception by Magnus's `catch_unwind` — see
[Thread-Per-Call Dispatch](./thread-per-call.md#interaction-with-catch_unwind-panic-safety)
for why a panic reaches this point as an ordinary exception, not an
in-flight unwind), pushes `[:error, e]` onto the per-call response queue,
and the calling Fiber's `response.pop` + explicit `raise(value)` re-raises
it. This is a small amount of code, but it is **hand-rolled**, unlike
thread-per-call's reliance on `Thread#value`'s built-in, well-tested
re-raise semantics. A bug in this rescue/repost path (e.g. forgetting the
`rescue` clause, or an exception class that doesn't serialize/re-raise
cleanly across the boundary) is a new failure mode thread-per-call simply
doesn't have.

There's a further subtlety: if the worker thread's `rescue => e` doesn't
catch something (e.g. an exception class outside `StandardError`, which
bare `rescue` doesn't catch), the worker thread dies silently and the pool
is now down a worker permanently, with no caller ever finding out beyond
its own call hanging forever on `response.pop`. Thread-per-call has no
equivalent risk — a dead spawned thread doesn't affect any other call.

## Summary

| Concern | Verdict |
|---|---|
| Spawn/teardown cost | None per call, avoided entirely versus thread-per-call |
| Memory overhead | Fixed (N workers' stacks), not proportional to concurrent call count |
| Lifecycle | Real design surface: eager vs. lazy start, `fork` safety, `at_exit` shutdown |
| Panic propagation | Manual — rescue in worker loop, repost via response queue, re-raise in caller; a missed edge case can wedge the pool |
| Concurrency ceiling | Bounded by pool size; N=1 serializes concurrent callers despite the wrapped crate supporting true concurrency |
