# Thread-Per-Call Dispatch

Spawn a brand-new `Thread.new { ... }` for every single `Duckling.parse`
invocation, `.value` (or `.join`) it from the calling Fiber, and let the
thread exit when the call completes. No persistent state, no lifecycle to
manage.

```ruby
def self.parse(text, **kwargs)
  Thread.new { parse_native(text, **kwargs) }.value
end
```

(`parse_native` standing in for whatever the actual GVL-released native
call ends up being named — that naming/implementation detail belongs to
the topic actually implementing issue #57, not this comparison.)

## OS thread creation/teardown cost

CRuby's `Thread.new` creates a genuine native OS thread — see the
[`Thread` class docs](https://docs.ruby-lang.org/en/3.3/Thread.html)
("Threads are implemented as native OS threads"). Two independent data
points on what that costs:

- **Measured locally**, Ruby 3.3.6 (`x86_64-darwin24`), this sandbox:
  2000 iterations of `Thread.new{}.join` in a tight loop averaged **~70
  microseconds per thread** (139ms / 2000). This is an empty block — pure
  create+schedule+teardown cost, no work done inside the thread.
- **Per-thread memory reservation**: `ruby(1)`'s documented defaults for
  thread stack sizes (`RUBY_THREAD_VM_STACK_SIZE` / `RUBY_THREAD_MACHINE_STACK_SIZE`),
  pinned to the `v3_3_6` tag matching this repo's CI Ruby version — see
  [`man/ruby.1#L727-L741`](https://github.com/ruby/ruby/blob/75015d4c1f6965b5e85e96fb309f1f2129f933c0/man/ruby.1#L727-L741):
  on a 64-bit CPU, a new thread reserves ~1MB for the VM stack and ~1MB for
  the machine stack by default (~2MB total), vs. a Fiber's ~128KB VM stack
  + ~512KB machine stack (~640KB total) — roughly 3x more per-thread
  reservation than a fiber, though both are virtual-memory reservations,
  not necessarily fully-committed physical pages.

Neither number is alarming for this gem's use case: `Duckling.parse` calls
are not fired in tight loops of thousands-per-second in the way a
web-request-per-fiber workload might be (that's the whole
`camping_trip_email`-shaped worst case in the benchmark table in the parent
doc — a single call already costs 791ms; the ~70µs spawn overhead is
0.009% of that). The one scenario where spawn overhead is proportionally
significant is the fastest inputs (`empty` at 24.1µs, `no_match` at
213.4µs) — see the parent README's recommendation section for why that
tradeoff is acceptable given issue #57's explicit non-goal of throughput
optimization.

## Where argument conversion happens

Two shapes are possible for the spawned thread's block:

1. **Spawn thread does everything, including arg parsing**: the Ruby
   method takes raw args, immediately does `Thread.new { Duckling.parse_native(*args, **kwargs) }.value`,
   and all Magnus-side `TryConvert`/`scan_args` work
   (see `ext/duckling/src/lib.rs`'s current
   [`scan_args`/`get_kwargs` calls](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/ext/duckling/src/lib.rs#L26-L45))
   happens on the spawned thread.
2. **Main thread does arg parsing, spawned thread only does the
   GVL-released native call**: validate/convert `locale`, `dims`,
   `reference_time`, `with_latent` into their Rust-side representations
   (`Locale`, `Vec<DimensionKind>`, `Context`, `Options`) on the calling
   thread first, then hand only those already-converted, `Send`-safe,
   non-Ruby-`Value` values into the spawned thread's closure, which does
   nothing but call `duckling::parse` (with the GVL released) and convert
   the resulting `Vec<Entity>` back to Ruby values afterward (on which
   thread, exactly, is itself a further sub-question — converting back to
   Ruby `Value`s requires holding the GVL, so that conversion has to happen
   either right before the spawned thread exits, while it still holds the
   GVL back, or after `.value` returns control to the calling thread).

Shape 2 is meaningfully safer: it confines the spawned thread's Ruby-object
surface to the smallest possible window (ideally: none at all, if entity
results can be converted back to plain Rust-owned data — `String`,
integers, enum tags — and only turned into Ruby `Value`s after control
returns to the original calling thread/Fiber). This sidesteps having to
reason carefully about Magnus's `Value`/GC-safety rules
(a magnus `Value` must not be stashed across a boundary where the GC could
run without the VM being able to see it as a GC root) on a thread whose
whole lifecycle is "spawn, do one call, die" — precisely the kind of
short-lived, easy-to-get-subtly-wrong scenario worth avoiding by
construction rather than by careful discipline. This is a design decision
for whichever topic actually implements the fix, not settled here — but
shape 2 is the safer starting assumption.

Either shape's `ArgumentError`-raising validation (invalid `locale:`,
invalid `dims:` — see the existing
[`parse_locale`/`parse_dims`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/ext/duckling/src/lib.rs#L65-L92)
functions) doesn't need to run on a spawned thread at all under shape 2 —
which also means invalid-argument errors can fail fast, before ever paying
the thread-spawn cost.

## Interaction with `catch_unwind` panic-safety

Two independent panic-catching layers are already relevant here,
established by other research in this issue's tree:

1. **Magnus's own FFI dispatch already wraps every registered method call
   in `std::panic::catch_unwind`.** `ext/duckling/src/lib.rs` registers
   `parse` via `function!(parse, -1)`
   ([`init`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/ext/duckling/src/lib.rs#L14-L18)),
   with signature `fn parse(ruby: &Ruby, args: &[Value]) -> Result<RArray, Error>`
   — this matches magnus 0.8.2's `RubyFunctionCAry` trait, whose
   `call_handle_error` wraps the call in `catch_unwind` and converts any
   caught panic into a raised Ruby exception via `Error::from_panic` +
   `raise`, unconditionally (not gated behind any Cargo profile) — see
   [`method.rs#L1390-L1421`](https://github.com/matsadler/magnus/blob/bca4ea7afe6870f27c16f5ca68f2106a6390840a/src/method.rs#L1390-L1421)
   in the [magnus](https://github.com/matsadler/magnus) crate (pinned to
   the `0.8.2` tag, matching `magnus = "0.8"` in this gem's
   [`Cargo.toml`](https://github.com/cpb/duckling/blob/d4373a5da32f989b9a19690509cb722eaf09e82b/ext/duckling/Cargo.toml)).
   This applies identically regardless of which OS thread is running the
   call — the calling thread today, or a `Thread.new`-spawned thread once
   this fix lands — because it's Magnus's own trampoline around the Rust
   function body, unrelated to which thread invokes it.
2. **This does not cover the GVL-released callback itself.** Per the
   sibling `duckling-crate-thread-safety` research
   (`../duckling-crate-thread-safety/panic-safety.md` once merged), a raw
   `extern "C"` callback handed to `rb_thread_call_without_gvl` (the
   mechanism the fix is expected to use to actually release the GVL) is a
   separate FFI boundary Magnus's outer `catch_unwind` doesn't protect on
   its own — unwinding a panic through `rb_thread_call_without_gvl`'s own C
   stack frame is undefined behavior regardless of an outer Rust
   `catch_unwind` further up the call stack, so the fix needs its own
   `catch_unwind` immediately around that callback, unconditionally. This
   is orthogonal to dispatch strategy: it's needed whether the outer call
   runs on the main thread, a thread-per-call spawned thread, or a
   worker-pool thread.

Given both layers exist (magnus's outer one already, and the fix's own
inner one around the `without_gvl` callback), a panic anywhere in the call
graph becomes an ordinary raised `Ruby` exception on whichever thread is
executing — by the time it would reach the spawned thread's block boundary,
it is already a normal Ruby exception, not an in-flight unwind.

**Propagation via `Thread#value`**: an unhandled exception raised inside a
`Thread.new` block is captured by that `Thread` object, not silently
dropped and not automatically re-raised elsewhere — calling `#value` (or
`#join`) on that thread from the caller re-raises it in the caller's
context. This is documented, standard behavior:

> When an unhandled exception is raised inside a thread, it will terminate. [...] The bang version of the exception raising methods (`Thread#raise`), when called with no thread, raises in `Thread.current`. [`Thread#value`] has the same properties as `#join` regarding unhandled exceptions.

— [`Thread` class docs](https://docs.ruby-lang.org/en/3.3/Thread.html) (see
`#join` and `#value`; `Thread.new{ raise "x" }.value` re-raises
`RuntimeError: x` in the caller, confirmed against the documented
behavior). No explicit handling is needed on top of this: a straightforward
`Thread.new { ... }.value` already gets correct exception propagation for
free, for both ordinary `Err(Error)` returns and caught panics converted to
exceptions by either `catch_unwind` layer above.

One caveat: `Thread.abort_on_exception` and `$DEBUG` global settings, if
enabled process-wide by the embedding application, change how an unhandled
exception in *any* thread is handled (immediate propagation to the main
thread rather than deferred to `#join`/`#value`). This gem doesn't need to
set or rely on either — plain `#value` is sufficient and doesn't depend on
global interpreter state the gem doesn't control.

## Summary

| Concern | Verdict |
|---|---|
| Spawn/teardown cost | ~70µs measured locally; negligible-to-moderate depending on scenario (see parent README) |
| Memory overhead | ~2MB reserved (mostly virtual) per in-flight call, 64-bit default |
| Arg-conversion thread | Prefer: validate/convert on caller thread, spawned thread only does the native call |
| Panic propagation | Free via `Thread#value`, once the fix adds its own `catch_unwind` around the `without_gvl` callback (a requirement independent of dispatch strategy) |
| Concurrency ceiling | One real OS thread per in-flight call — bounded only by the OS and the wrapped crate's confirmed thread-safety |
