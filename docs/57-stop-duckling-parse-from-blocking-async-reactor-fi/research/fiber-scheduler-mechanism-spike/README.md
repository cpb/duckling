# Fiber-Scheduler Mechanism Spike

Empirical answer to: **what mechanism does `Duckling.parse` actually need so
it stops stalling sibling `Fiber`s inside a single-OS-thread `async` reactor,
given the gem's Ruby floor of `>= 3.2.0` (CI pins `3.3.6`)?**

This is a prototype spike for issue #57. Every measurement below was produced
by temporarily editing `ext/duckling/src/lib.rs` / `lib/duckling.rb`,
recompiling with `bundle exec rake compile`, and running the existing
`test/falcon_fiber_blocking_test.rb` — then discarding those edits. No
application code changed as a result of this research; see `git log` for
this commit's diff (docs only).

## Documents

| Document | Description |
|---|---|
| [Raw measurements](results.md) | Full pass/fail + `max_gap`/`parse_duration` table for every approach × Ruby-version combination tried. |

## Test fixture

`test/falcon_fiber_blocking_test.rb` (added on the issue-57 branch, not yet
merged to `main`) runs an `Async::Reactor` (via the `Sync` block from the
`async` gem) with two sibling `Fiber`s: a "ticker" that sleeps 1ms in a loop
and records the wall-clock gap between ticks, and a "parser" that makes one
`Duckling.parse` call against a long representative paragraph partway
through the ticker's run. It asserts the largest observed ticker gap stays
within 11ms (`TICK_INTERVAL` 1ms + `NON_BLOCKING_TOLERANCE` 10ms) of the
requested interval — i.e., that `Duckling.parse` does not stall the ticker.

Reproducing the baseline failure (`bundle exec ruby -I test
test/falcon_fiber_blocking_test.rb` on Ruby 3.3.6, `release` Cargo profile)
confirms the claim: max ticker gap 0.1363s against a measured
`Duckling.parse` duration of 0.1361s — the gap tracks the parse duration
almost exactly, exactly the signature of a GVL-held blocking call never
yielding to the reactor. Full numbers, including a `dev`-profile run
(~10x slower, same shape), are in [Raw measurements](results.md).

## Approach A: `rb_thread_call_without_gvl` alone

The textbook fix: wrap just the blocking `duckling_parse(...)` call (from
[duckling](https://github.com/wafer-inc/duckling)) in
`rb_sys::rb_thread_call_without_gvl`, called directly within the native
`parse` function on whatever thread Ruby invoked it on — no Ruby-level
`Thread` spawn. Magnus 0.8.2 has no safe wrapper for this; it requires the
`rb-sys` Cargo feature (`magnus = { version = "0.8", features = ["rb-sys"] }`)
to reach `magnus::rb_sys::catch_unwind` (confirmed present at
[magnus 0.8.2's `src/rb_sys.rs`](https://github.com/matsadler/magnus/blob/bca4ea7afe6870f27c16f5ca68f2106a6390840a/src/rb_sys.rs))
plus the raw `rb_sys::rb_thread_call_without_gvl` FFI binding (generated at
build time from Ruby's C headers, not vendored as source in the `rb-sys`
crate itself).

**Result: fails on both Ruby 3.3.6 and 3.4.5.** Max ticker gap tracks parse
duration almost exactly in every run (see
[Raw measurements](results.md#approach-a-alone-rb_thread_call_without_gvl-around-duckling_parse-no-ruby-level-thread-spawn)) —
confirming the hypothesis this spike set out to test: on a single-OS-thread
`async` reactor, releasing the GVL only lets *other OS threads* make
progress. It doesn't free up *this* OS thread, which is still physically
executing `duckling_parse`'s machine code the whole time, so the
cooperatively-scheduled ticker `Fiber` — which lives on that same OS thread
— never gets a chance to run.

### Why Approach A alone isn't enough, even on Ruby 3.4.5

This spike initially expected Approach A to at least pass on Ruby 3.4.5,
where `Fiber::Scheduler#blocking_operation_wait` exists and the installed
`async` gem (2.42.0, well past the 2.21.1 minimum) implements it — its
`blocking_operation_wait` hook dispatches to a worker-thread pool (see
[`socketry/async`'s `lib/async/scheduler.rb` at v2.42.0](https://github.com/socketry/async/blob/v2.42.0/lib/async/scheduler.rb#L51-L62)).
It didn't pass. Tracing into Ruby's own C source explains precisely why:
`rb_thread_call_without_gvl` is a thin wrapper around the more general
`rb_nogvl(func, data1, ubf, data2, flags)`, called with **`flags == 0`**:

```c
void *
rb_thread_call_without_gvl(void *(*func)(void *data), void *data1,
                            rb_unblock_function_t *ubf, void *data2)
{
    return rb_nogvl(func, data1, ubf, data2, 0);
}
```
([ruby/ruby `thread.c` at tag `v3_4_5`, lines 1686–1690](https://github.com/ruby/ruby/blob/v3_4_5/thread.c#L1686-L1690))

`rb_nogvl` only calls into the scheduler's `blocking_operation_wait` hook
(via `rb_fiber_scheduler_blocking_operation_wait`) when the caller passes the
`RB_NOGVL_OFFLOAD_SAFE` flag:

```c
void *
rb_nogvl(void *(*func)(void *), void *data1,
         rb_unblock_function_t *ubf, void *data2,
         int flags)
{
    if (flags & RB_NOGVL_OFFLOAD_SAFE) {
        VALUE scheduler = rb_fiber_scheduler_current();
        if (scheduler != Qnil) {
            /* ... calls rb_fiber_scheduler_blocking_operation_wait ... */
        }
    }
    /* ... falls through to the ordinary (non-offloaded) GVL-release path ... */
```
([ruby/ruby `thread.c` at tag `v3_4_5`, lines 1539–1554](https://github.com/ruby/ruby/blob/v3_4_5/thread.c#L1539-L1554);
`RB_NOGVL_OFFLOAD_SAFE` is defined at
[`include/ruby/thread.h`, line 73](https://github.com/ruby/ruby/blob/v3_4_5/include/ruby/thread.h#L73)
and does not exist at all in the `v3_3_6` tag of the same header — confirming
this flag, and the `blocking_operation_wait` auto-offload path it gates, is
new in Ruby 3.4, consistent with [Feature #13557](https://bugs.ruby-lang.org/issues/13557)).

`rb_thread_call_without_gvl` never sets that flag, so `blocking_operation_wait`
is simply never invoked for it — regardless of Ruby version or whether the
active scheduler implements the hook. Getting the Ruby-3.4+ auto-offload
behavior would require calling the lower-level `rb_nogvl` directly with
`RB_NOGVL_OFFLOAD_SAFE` explicitly set, not the convenience wrapper this
spike (and most existing native-extension code) reaches for.

## Approach B alone: background `Thread`, GVL still held

Isolating the other half of the candidate fix: `Duckling.parse` (Ruby level)
spawns `Thread.new { native_call }.value`, but the native call underneath
still invokes `duckling_parse` directly — no GVL release.

**Result: also fails** (see
[Raw measurements](results.md#approach-b-alone-background-thread-but-gvl-not-released-in-the-native-call)).
A second OS thread now exists, but it holds the GVL for the entire
`duckling_parse` call, and MRI's global lock has no safepoint inside a
non-yielding native call for the reactor's OS thread to reclaim it at — so
the ticker `Fiber`, which needs the GVL to execute its own Ruby bytecode
(`task.sleep`, gap bookkeeping), is starved just as completely as in the
baseline, just via a different thread.

## Approach A+B combined: `rb_thread_call_without_gvl` *and* a background `Thread`

`Duckling.parse` (Ruby level) becomes:

```ruby
def self.parse(*args, **kwargs)
  Thread.new { _native_parse_spike(*args, **kwargs) }.value
end
```

with `_native_parse_spike` being the native method that wraps
`duckling_parse(...)` in `rb_thread_call_without_gvl` (Approach A).

**Result: passes consistently — 11/11 runs across Ruby 3.3.6 and 3.4.5**,
`max_gap` two orders of magnitude below the pass threshold in every run (see
[Raw measurements](results.md#approach-ab-combined-rb_thread_call_without_gvl-and-a-spawned-background-thread)).
Existing correctness tests (`test/duckling_test.rb`,
`test/duckling_comma_list_test.rb`) stayed green against every variant
tested, confirming the mechanism change doesn't alter `Duckling.parse`'s
return values.

## Mechanism explanation: `block`/`unblock` vs. `blocking_operation_wait`

Two distinct `Fiber::Scheduler` hook pairs are in play, and the difference
between them is exactly why Approach B's `Thread.new { ... }.value` works on
the 3.2/3.3 floor without needing anything 3.4-specific:

- **`block`/`unblock`** — invoked by `Thread#join` (among other blocking
  primitives like `Mutex#lock`/`#unlock`) to tell the scheduler "the current
  Fiber is waiting on something; here's a `Fiber` to wake up once it's
  done." Present in the very first `Fiber::SchedulerInterface` design:
  [Ruby 3.0.0's `Fiber::SchedulerInterface` docs](https://ruby-doc.org/core-3.0.0/Fiber/SchedulerInterface.html)
  document both methods with language ("Invoked by methods like
  `Thread#join`... `Mutex#lock` calls `block` and `Mutex#unlock` calls
  `unblock`") essentially unchanged through
  [Ruby 3.3's `Fiber::Scheduler` docs](https://docs.ruby-lang.org/en/3.3/Fiber/Scheduler.html).
  Because `Thread#join`/`Thread#value` already goes through this hook pair,
  spawning a background `Thread` around the native call lets the *calling*
  Fiber yield back to the reactor the moment it starts waiting — no
  Ruby-version-specific opt-in required.
- **`blocking_operation_wait`** — confirmed absent from both the
  [Ruby 3.0.0](https://ruby-doc.org/core-3.0.0/Fiber/SchedulerInterface.html)
  and [Ruby 3.3](https://docs.ruby-lang.org/en/3.3/Fiber/Scheduler.html)
  scheduler docs, and present in
  [Ruby 3.4's `Fiber::Scheduler` docs](https://docs.ruby-lang.org/en/3.4/Fiber/Scheduler.html)
  ("Invoked by Ruby's core methods to run a blocking operation in a
  non-blocking way"), matching [Feature #13557](https://bugs.ruby-lang.org/issues/13557).
  It's a VM-driven *auto-offload* path — intended so a C extension (or Ruby
  stdlib method) that releases the GVL via the right low-level API doesn't
  have to manually spawn a thread itself; the VM does it via the scheduler.
  But as shown above, it's gated behind `RB_NOGVL_OFFLOAD_SAFE`, a flag only
  reachable through the lower-level `rb_nogvl`, not through
  `rb_thread_call_without_gvl`. It also doesn't exist pre-3.4 at all, which
  rules it out unconditionally for this gem's floor.

## Conclusion

For a fix that works on this gem's actual Ruby floor (`>= 3.2.0`, CI-pinned
to `3.3.6`), **both** pieces of the combined approach are required —
neither is sufficient alone:

1. **Release the GVL around the blocking native call** (`rb_thread_call_without_gvl`
   wrapping `duckling_parse(...)` in `ext/duckling/src/lib.rs`), so that a
   spawned background `Thread` running that call doesn't hold the GVL
   hostage for the call's full duration (Approach B alone, GVL held, still
   failed).
2. **Spawn a genuine background `Thread`** around the (now GVL-releasing)
   native call from the Ruby-level `Duckling.parse` method, so the calling
   Fiber can yield to the reactor via `Thread#value`'s `block`/`unblock`
   scheduler hooks — hooks that have existed since Ruby 3.0's original
   `Fiber::SchedulerInterface`, unlike `blocking_operation_wait` (Approach A
   alone, no Thread spawn, still failed on both 3.3.6 and 3.4.5).

This combination needs no Ruby-3.4-only API and passed consistently on both
3.3.6 (CI's pinned version) and 3.4.5. `blocking_operation_wait` is real and
does land in Ruby 3.4, but it isn't a substitute here: it requires the
`RB_NOGVL_OFFLOAD_SAFE` flag on the lower-level `rb_nogvl`, which
`rb_thread_call_without_gvl` never sets, so it would not fire for this call
even after a floor bump to 3.4+ unless the native code were rewritten to
call `rb_nogvl` directly with that flag — a separate, later decision, not
part of this spike's recommendation.

## Open follow-ups

- This spike prototyped the `Thread`-spawn wrapper at the Ruby level
  (`lib/duckling.rb` calling a renamed native binding). The task description
  also floated spawning the thread from Rust via Magnus's
  `Ruby::thread_create_from_fn`; that alternative was not prototyped here
  since the simpler Ruby-level wrapper already met the bar — worth a quick
  ergonomics comparison before implementation if the actual fix PR wants to
  avoid a public-API rename (`_native_parse_spike` here was throwaway).
- Every prototype here awaited the spawned Thread with `.value`; the
  interaction between `Thread#value`'s exception-propagation behavior and
  the existing `ArgumentError`-raising paths in
  `parse_locale`/`parse_dims`/`build_context` wasn't specifically exercised
  here beyond the existing test suite staying green, and deserves an
  explicit test in the real fix.
- Numbers in [Raw measurements](results.md) come from a single macOS
  (x86_64-darwin24) development machine; CI runs on GitHub-hosted Linux
  runners, so absolute `parse_duration`/`max_gap` figures will differ there
  — only the qualitative pass/fail shape is expected to generalize.
- Whether a future floor bump to Ruby 3.4+ would justify *also* wiring the
  `RB_NOGVL_OFFLOAD_SAFE`-flagged `rb_nogvl` path (to let `async`'s own
  worker-pool `blocking_operation_wait` handle the offload instead of a
  gem-managed `Thread.new`) is out of scope for this spike and the user's
  decision to stay within the 3.2/3.3 floor for now.
