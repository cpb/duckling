# Current terrain: `Duckling.parse`'s Fiber-scheduler dispatch (baseline for issue #71)

Pure observable fact about the system as built today, on branch
`issue-71/pool-worker-threads-for-fiber-scheduler-dispatch-i` at commit
`bef4e24`. No design opinions about the worker-pool replacement live here —
this is the baseline any pool design must reproduce (dispatch semantics,
error semantics, GC safety) and improve on (per-call `Thread.new`/`join`
cost).

## 1. `lib/duckling.rb` — the dispatch wrapper

`Duckling.parse` (`lib/duckling.rb:36-48`) is the only public entrypoint;
`Duckling::Native.parse` (defined by the compiled extension) is the raw one.

- `lib/duckling.rb:37-40` — `reference_time:` coercion. If `kwargs[:reference_time]`
  is present, is not already a `Time`, and responds to `#to_time`, it's replaced
  with `reference_time.to_time` before anything is dispatched. This lets
  `ActiveSupport::TimeWithZone`/stdlib `DateTime` work even though
  `Duckling::Native.parse`'s Magnus binding only accepts a strict
  `kind_of?(Time)` (see `ext/duckling/src/lib.rs:214`, `RubyTime` param type).
  This coercion happens identically regardless of which dispatch path is
  taken below — any pool replacement must keep it in the Ruby-level wrapper,
  not push it into the pool worker.
- `lib/duckling.rb:42` — `return Native.parse(*args, **kwargs, &block) unless Fiber.scheduler`.
  `Fiber.scheduler` is a per-thread check (`Fiber.scheduler` reads the
  scheduler installed on the *calling* thread, e.g. via `Fiber.set_scheduler`
  inside an `Async` reactor's `Sync`/`Async` block). When absent — the plain
  Puma/Sidekiq thread-pool case — `Native.parse` is called directly, in the
  calling thread, with zero extra `Thread` spawned. This is the fast path
  `test/thread_pool_dispatch_test.rb` pins.
- `lib/duckling.rb:44-47` — when a scheduler *is* installed:
  ```ruby
  Thread.new do
    Thread.current.report_on_exception = false
    Native.parse(*args, **kwargs, &block)
  end.value
  ```
  `report_on_exception = false` is set as the first statement *inside* the
  spawned thread body, not on the `Thread` object after `Thread.new` returns
  — setting it afterward would race a thread that fails fast enough to
  finish (and print its backtrace) before the assignment lands. `.value`
  both blocks until the thread finishes and re-raises any exception the
  thread body raised, as ordinary Ruby control flow the caller can `rescue`.
- Comment block `lib/duckling.rb:7-35` is the canonical rationale (see §3
  below) — it is the single source of truth this file's other prose and
  `ext/duckling/src/lib.rs:15-22` both point back to.

## 2. `ext/duckling/src/lib.rs` — the GVL-release mechanism

- **Raw FFI call**: `ext/duckling/src/lib.rs:250-258`, inside `fn parse` (the
  Magnus binding for `Duckling::Native.parse`):
  ```rust
  unsafe {
      rb_sys::rb_thread_call_without_gvl(
          Some(parse_without_gvl),
          &mut payload as *mut ParsePayload as *mut c_void,
          None, // ubf: no cancellation hook
          std::ptr::null_mut(),
      );
  }
  ```
  This is the raw `rb_thread_call_without_gvl` C API (via the `rb-sys` crate),
  called directly because Magnus 0.8.2 has no safe wrapper for GVL release
  (documented separately in the `magnus-rb-sys-gvl-release` research topic,
  git history commit `2029f2b`; referenced from `lib.rs:15-22`'s comment). The
  `ubf` (unblocking-function) argument is `None` — `Thread#raise`/`#kill`
  against an in-flight parse is explicitly out of scope (comment at
  `lib.rs:254-256`).
- **`ParsePayload` struct** (`ext/duckling/src/lib.rs:39-46`):
  ```rust
  struct ParsePayload {
      text: String,
      locale: Locale,
      dims: Vec<DimensionKind>,
      context: Context,
      options: Options,
      result: Option<Result<Vec<Entity>, String>>,
  }
  ```
  Confirmed: every field is plain owned Rust data (`String`, the crate's own
  `Locale`/`DimensionKind`/`Context`/`Options` enums/structs, and
  `Option<Result<Vec<Entity>, String>>` for the outcome — `Entity` is the
  wrapped `duckling` crate's own plain data type, and the error variant is a
  `String`, not a `magnus::Error`). No `magnus::Value`, no `RHash`/`RArray`,
  no `magnus::Error` anywhere in the struct, in either direction. The struct
  lives on the calling function's stack frame (`lib.rs:241-248`); no heap
  allocation or ownership transfer happens across the GVL-release boundary,
  since `rb_thread_call_without_gvl` runs the callback to completion before
  returning — the borrow simply ends when the call returns
  (`lib.rs:235-240`'s comment).
- **`catch_unwind` panic guard**: the off-GVL callback `parse_without_gvl`
  (`ext/duckling/src/lib.rs:61-84`) wraps the actual `duckling_parse(...)`
  call in `catch_unwind(AssertUnwindSafe(|| ...))` (lines 66-74) — not
  `magnus::rb_sys::catch_unwind` — specifically so the "no Ruby-VM-touching
  type crosses this callback" invariant (§6 below) stays mechanically
  simple: the callback only ever writes `payload.result`, a plain
  `Option<Result<Vec<Entity>, String>>`. This guard is unconditional, not
  release-profile-only defense-in-depth: the wrapped `duckling` crate's own
  internal `catch_unwind` is compiled out under
  `#[cfg(not(debug_assertions))]` (`lib.rs:56-60`), which is *absent* from
  this repo's own `dev`-profile local default
  (`RB_SYS_CARGO_PROFILE=dev`, set via `.env.local`) — so without this
  wrapper-level guard, a panic during local dev work (`dev` profile) would
  propagate as a real Rust unwind across the FFI boundary, which is
  undefined behavior.
- **Panic → `RuntimeError` surfacing**: `panic_message` (`lib.rs:88-96`)
  downcasts the caught `Box<dyn Any + Send>` payload to `&'static str` or
  `String` (falling back to `"no panic message"`), producing a plain Rust
  `String` — still no Ruby type. Back on the GVL-holding side, `fn parse`
  (`lib.rs:206-275`) reads `payload.result` *after* `rb_thread_call_without_gvl`
  returns — i.e. after the GVL is confirmed reacquired (comment at
  `lib.rs:265-267`) — and on `Err(message)` calls `panic_error(ruby, &message)`
  (`lib.rs:108-113`):
  ```rust
  fn panic_error(ruby: &Ruby, message: &str) -> Error {
      Error::new(
          ruby.exception_runtime_error(),
          format!("duckling::parse panicked: {message}"),
      )
  }
  ```
  This deliberately uses `ruby.exception_runtime_error()` (a `StandardError`
  subclass, i.e. `RuntimeError`) rather than Magnus's own `Error::from_panic`
  convention (which raises the unrescuable `fatal`) — a native panic must be
  an ordinary `rescue => e`-able error to the Ruby caller, since it cost the
  caller nothing but this one call (`lib.rs:103-107` comment). This is the
  exact error object that later propagates through `Thread#value`'s
  re-raise in `lib/duckling.rb:47` to the original caller.

## 3. Why a bare GVL release doesn't unblock an Async::Reactor Fiber

Cited verbatim from `lib/duckling.rb:7-15` (the canonical statement) and
mirrored in `ext/duckling/src/lib.rs:15-22`:

> Native.parse already releases the GVL around the native call, but a bare
> GVL release alone does not hand control back to an Async::Reactor —
> Ruby 3.4's Fiber::Scheduler#blocking_operation_wait auto-offload path
> requires a flag rb_thread_call_without_gvl never sets. Spawning a real
> background Thread lets the calling Fiber yield to the reactor via
> Thread#value's block/unblock scheduler hooks instead, which have been
> present since Ruby 3.0.

Corroborating detail from PR #50's description (`git log`, commit `1f10e65`,
merging issue #64): the empirical spike this rationale rests on is recorded
on the project wiki at
`research-fiber-scheduler-mechanism-spike` (linked from both files above),
not in this repo's tracked source — it isn't re-derivable from `git log`
alone, only from the PR's own prose and the code comments that summarize its
conclusion.

The mechanism, restated precisely from what's in-repo:
- `rb_thread_call_without_gvl` (the raw C API `ext/duckling/src/lib.rs:250`
  calls) releases the GVL for the duration of the callback so *other OS
  threads* holding/waiting on the GVL can run — this is sufficient for a
  plain multi-threaded pool (Puma/Sidekiq: `test/thread_pool_dispatch_test.rb`),
  where concurrency comes from OS-thread preemption between GVL holders.
- An `Async::Reactor`-scheduled Fiber is different: it cooperatively
  schedules multiple Fibers on a *single* OS thread
  (`test/falcon_fiber_blocking_test.rb:13-15`'s comment). For a sibling
  Fiber to run while one Fiber is "blocked," the reactor needs to be told to
  switch away — Ruby 3.4's `Fiber::Scheduler#blocking_operation_wait` hook
  is the mechanism for that, and it is driven by a flag that only
  `Thread`-level blocking primitives (like `Thread#value`/`Thread#join`) set
  on the calling thread — `rb_thread_call_without_gvl` by itself never sets
  it, since it only concerns GVL ownership, not Fiber-scheduler
  notification. `Thread#value`'s block/unblock hooks (present since Ruby
  3.0, per the `lib/duckling.rb:12-13` comment) are what actually cause the
  scheduler notification, which is why the fix requires spawning a full
  background `Thread`, not just releasing the GVL.
- This asymmetry is exactly what `lib/duckling.rb:17-22`'s comment states as
  the reason the `Thread.new` is conditional on `Fiber.scheduler` being
  present: a plain thread pool never needed the `Thread.new` — it already
  gets its concurrency from the GVL release alone — so paying the
  `Thread.new`/`join` cost there is pure overhead with no corresponding
  benefit.

Note for corroboration: this document does not independently re-verify the
`Fiber::Scheduler#blocking_operation_wait` claim against upstream Ruby docs
or bug-tracker discussion beyond what's already cited in-repo — the
empirical spike backing it lives on the project wiki
(`research-fiber-scheduler-mechanism-spike`), outside this git repo's
history, and a related later spike (commit `875a840`,
"research(77): spike confirms rb_nogvl + RB_NOGVL_OFFLOAD_SAFE obviates
Thread wrapper on Ruby 3.4+", also migrated off-repo per commit `d0fd3a8`)
suggests the underlying constraint may be narrower on Ruby 3.4+ specifically
than the general statement above — that nuance is out of scope for this
current-terrain document (it bears on future dispatch-mechanism design, not
on what's built today) but is worth flagging to whichever research/plan
topic addresses pool-worker GVL semantics.

## 4. `test/falcon_fiber_blocking_test.rb` — what it asserts and how

- **Asserted behavior** (`test_duckling_parse_does_not_stall_other_fibers_in_async_reactor`,
  lines 85-151): inside a single-OS-thread `Async::Reactor` (`Sync do ... end`,
  line 96), a "ticker" Fiber sleeping every `TICK_INTERVAL` (1ms, line 65)
  must not observe a gap between ticks that is comparable to the duration of
  a concurrent `Duckling.parse` call made by a sibling "parser" Fiber. If
  `Duckling.parse` blocked the reactor's one OS thread for its whole native
  execution (the pre-#64 behavior), every ticker gap during that window
  would equal ~100% of the parse duration; the fix's success criterion is
  that gaps stay well below that.
- **Scenario construction**: a `LONG_PARAGRAPH` fixture (lines 40-62, ~300
  words of representative LLM-style prose with dates/times/durations/money)
  is parsed once via `Duckling.parse(LONG_PARAGRAPH, locale: "en",
  reference_time: REFERENCE_TIME)` inside the `parser` `Async` task
  (lines 114-126), started after `TICKS_BEFORE_PARSE` (20) ticks have
  already elapsed to establish a baseline rhythm, with `TICKS_AFTER_PARSE`
  (20) more ticks recorded afterward. A warm-up call (line 90) outside the
  timed reactor run absorbs the one-time lazy-static/regex-compile cost so
  it isn't attributed to the parse under test.
- **Assertion mechanics** (lines 132-150): proportional, not absolute —
  `allowance = [TICK_INTERVAL + (parse_duration * BLOCKING_FRACTION), MIN_GAP_ALLOWANCE].max`
  where `BLOCKING_FRACTION = 0.5` (line 78) and `MIN_GAP_ALLOWANCE = 0.025`
  (line 83), then `assert_operator max_gap, :<, allowance`. Scaling the
  allowance by the measured `parse_duration` itself (rather than a fixed
  ms bound) means a slow/loaded CI runner stretches the allowance along
  with the parse duration it's timing, so ordinary scheduling jitter or a
  GC pause can't produce a spurious failure that would be misread as a
  reactor stall.

## 5. `test/thread_pool_dispatch_test.rb` — what it asserts and how

- **Asserted behavior** (`test_plain_thread_pool_callers_pay_no_per_call_thread_spawn`,
  lines 65-99): when no `Fiber.scheduler` is installed on the calling
  thread (`skip "test requires no ambient Fiber scheduler" if Fiber.scheduler`,
  line 66) — the Puma/Sidekiq-style plain-thread-pool model — `Duckling.parse`
  must spawn **zero** additional `Thread`s per call, across
  `POOL_SIZE` (4) worker threads each making `REQUESTS_PER_WORKER` (5) calls
  (20 calls total).
- **How "zero thread spawn" is verified** — instrumentation, not a
  before/after `Thread.list.count` snapshot: `SpawnCounter`
  (lines 31-41) is a module `prepend`ed onto `Thread`'s singleton class
  (`Thread.singleton_class.prepend(SpawnCounter)`, line 60, installed once
  via a `setup` guard) that overrides `Thread.new` to increment a
  thread-local `Counter` (lines 43-56, mutex-guarded) before calling `super`,
  but *only* when `Thread.current[:duckling_spawn_counter]` is set. Each of
  the 4 pool-worker threads sets that thread-local to a shared `Counter`
  instance for the duration of its `Duckling.parse` calls
  (lines 76, 81), so the count is scoped to `Thread.new` calls made *from
  inside* a worker while parsing — i.e. spawn overhead attributable to
  `Duckling.parse` itself — and excludes the pool's own worker-thread setup
  (the outer `Thread.new` at line 72) and any spawns from unrelated
  concurrent tests. Final assertion: `assert_equal 0, counter.count`
  (line 92).
- The file's own comment (lines 16-17) is the primary in-repo citation for
  the PR-era overhead numbers used in §7 below.

## 6. GC-safety rule: no `magnus::Value`/`magnus::Error` across the pool boundary

Documented in two places, consistently:
- **In-repo, at the point it matters**: `ext/duckling/src/lib.rs:34-38`,
  the doc comment directly on `struct ParsePayload`:
  > Deliberately holds only fully-owned Rust data — no `magnus::Value`, no
  > `magnus::Error`, no other Ruby-VM-touching type crosses this struct in
  > either direction (this repo's established rule: never stash a bare
  > `magnus::Value`, or anything wrapping one, across a Magnus call boundary
  > — a past incident here caused a real GC-safety segfault).
  Reinforced again at the callback itself, `ext/duckling/src/lib.rs:48-54`:
  "no Ruby method calls, no `Value`/`RArray` construction, no `magnus::Error`
  construction or raising is permitted here."
- **User memory** (`feedback-magnus-value-gc-safety.md`): states the
  mechanism precisely — a `magnus::Value` pulled off a Ruby container (e.g.
  via `RHash::foreach` with `ForEach::Delete`) must never be held in a
  Rust-heap container (`Vec<Value>`, `Box<Value>`, a struct field) across any
  subsequent Magnus call that could trigger GC, because once off the
  Ruby-visible object graph, MRI's conservative stack-scanning GC can't see
  it and may free it before reuse. The concrete precedent: an in-place
  Hash key-symbolizer that collected deleted `(key, value)` pairs into a
  `Vec<(Value, Value)>` before reinserting passed all normal tests, then
  segfaulted under `benchmark-ips`/`GC.stat` load; fixed by staging the same
  data in a real, GC-visible Ruby `RArray` instead.

**Hard constraint for any pool design**: whatever struct/channel/queue carries
work into a pooled worker and results back out must, like today's
`ParsePayload`, hold only plain owned Rust data (`String`, the crate's own
value types, primitive `Option`/`Result`) — never a bare `magnus::Value`,
`RHash`, `RArray`, or `magnus::Error`, and never any type wrapping one, in a
heap-allocated container (`Vec`, `Box`, a long-lived struct field) that
outlives a single stack frame. A pool's worker-side queue is exactly such a
heap container, so this constraint applies to it directly, not just to the
current stack-local `ParsePayload`.

## 7. Benchmark numbers: dispatch overhead vs `Native.parse`

**Scenario names** are from `benchmark/parse_benchmark.rb`'s `CORPUS` constant
(lines 47-54): `short` (`"tomorrow at 3pm"`), `medium` (`"from 13 to 15 of
July"`), `long` (`"meet me next Wednesday at 2:30pm for about 2 hours"`),
`no_match` (`"the quick brown fox jumps over the lazy dog"`), `empty`
(`""`), and `camping_trip_email` (an 18-time-entity multi-paragraph fixture,
lines 21-42). Each scenario is run twice per `Benchmark.ips` pass — once as
`Duckling.parse` (thread-per-call, only when wrapped in `Sync do ... end` so
a `Fiber.scheduler` is actually installed, per `run_ips`'s comment at
`parse_benchmark.rb:78-87`) and once with the `_native` suffix as
`Duckling::Native.parse` (no thread) — giving a same-run, same-hardware
overhead comparison.

- **PR-era citation** (`test/thread_pool_dispatch_test.rb:16-17`, referring
  to PR #50/issue #64's original benchmark run): "the PR's own benchmarks
  record +53% to +965% per-call overhead, and objects/call 28 → 35 with
  minor GC 1 → 62" for plain-thread-pool-shaped callers paying the
  (at-the-time-unconditional) thread-spawn tax.
- **Current recorded data** (`docs/benchmarks/README.md`, generated from
  `docs/benchmarks/<environment>/0.3.0-rc1.json`; auto-generated, never
  hand-edited — see `AGENTS.md`'s `docs/benchmarks/` entry), per-environment
  overhead on the fastest (most dispatch-overhead-sensitive) scenarios,
  `Duckling.parse` (thread-per-call) vs `Duckling::Native.parse`:
  - `github-actions`: `short` +30.5%, `no_match` +75.3%, `empty` +532.4%
    (`docs/benchmarks/README.md:47-51`).
  - `claude-code-web`: `short` +62.6%, `no_match` +146.4%, `empty` +859.7%
    (`docs/benchmarks/README.md:84-88`).
  - `local-3.3`: `short` -60.3% (thread-per-call faster — noisy/small-sample
    local run), `no_match` -32.9%, `empty` +378.8%
    (`docs/benchmarks/README.md:121-125`).
  - `local-3.4`: `short` +39.0%, `no_match` +116.8%, `empty` +948.3%
    (`docs/benchmarks/README.md:158-162`).
  In every environment, overhead is largest on `empty` (the scenario with
  the least native work to amortize the thread-spawn/join cost against) and
  shrinks toward negligible on `long`/`camping_trip_email` (per-call native
  work already dominates). This is the same qualitative pattern PR #50
  originally recorded and the pattern any pool-based replacement is being
  built to flatten.

## Sequence diagram: current dispatch flow

```mermaid
sequenceDiagram
    participant CF as Calling Fiber<br/>(Async::Reactor)
    participant DP as Duckling.parse<br/>(lib/duckling.rb)
    participant TH as Spawned Thread
    participant NP as Native.parse<br/>(Magnus, ext/duckling/src/lib.rs)
    participant RS as duckling::parse<br/>(Rust, GVL released)

    CF->>DP: Duckling.parse(text, reference_time: ...)
    DP->>DP: coerce reference_time via #to_time
    DP->>DP: Fiber.scheduler present?
    alt Fiber.scheduler installed (Async reactor)
        DP->>TH: Thread.new { report_on_exception = false; Native.parse(...) }
        Note over CF,TH: Thread#value's block/unblock hooks let CF<br/>yield to sibling Fibers on the reactor
        TH->>NP: Native.parse(text, locale:, dims:, reference_time:, with_latent:)
        NP->>NP: rb_thread_call_without_gvl(parse_without_gvl, payload)
        NP->>RS: duckling_parse(text, locale, dims, context, options)<br/>[GVL released; other threads/reactor free to run]
        RS-->>NP: Vec<Entity> or panic (caught via catch_unwind)
        NP->>NP: GVL reacquired; build Ruby Array of entity Hashes
        NP-->>TH: Array of entities (or raise RuntimeError on panic)
        TH-->>DP: Thread#value (blocks TH's caller, re-raises exceptions)
        DP-->>CF: return entities
    else no Fiber.scheduler (plain thread pool: Puma/Sidekiq)
        DP->>NP: Native.parse(...) directly, no Thread spawned
        NP->>NP: rb_thread_call_without_gvl(parse_without_gvl, payload)
        NP->>RS: duckling_parse(...) [GVL released]
        RS-->>NP: Vec<Entity> or panic
        NP-->>DP: Array of entities (or raise RuntimeError)
        DP-->>CF: return entities
    end
```
