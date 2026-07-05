# Raw experiment data

All runs on x86_64-darwin24, Cargo release profile, `duckling.gemspec`'s pinned dependency
versions (`magnus 0.8.2`, `rb-sys 0.9.128`, `duckling 0.4.0` per `Cargo.lock`).

## Structural pre-check: `rb_fiber_scheduler_blocking_operation_extract` availability

```
for v in 3.2.2 3.3.6 3.3.8 3.4.4 3.4.5 3.4.10 4.0.5; do
  grep -rl "rb_fiber_scheduler_blocking_operation_extract" ~/.rbenv/versions/$v/include/
done
```

| Ruby version | Symbol present in headers? |
|---|---|
| 3.2.2 | no |
| 3.3.6 | no |
| 3.3.8 | no |
| 3.4.4 | no |
| 3.4.5 | no |
| 3.4.10 | no |
| 4.0.5 | **yes** (`ruby/fiber/scheduler.h`) |

Live `have_func` check (`mkmf`) confirmed: fails on 3.4.10 ("no"), succeeds on 4.0.5 ("yes").
`io-event 1.19.1`'s `ext/extconf.rb`:

```ruby
if have_func("rb_fiber_scheduler_blocking_operation_extract")
  if have_header("pthread.h")
    append_cflags(["-DHAVE_IO_EVENT_WORKER_POOL"])
    $srcs << "io/event/worker_pool.c"
  end
end
```

`Async::Scheduler.new.respond_to?(:blocking_operation_wait)`: `false` by default, `true` with
`ASYNC_SCHEDULER_WORKER_POOL=true` set — but only on Ruby 4.0.5 (where `WorkerPool` compiled at
all); on 3.4.10 `IO::Event.const_defined?(:WorkerPool)` is `false` regardless of the env var.

## Track 2 — Ruby 3.4.10, hand-rolled scheduler (`test/spike_77_minimal_scheduler_test.rb`)

Scheduler subclass counts `blocking_operation_wait` invocations directly; ticker Fiber ticks every
1ms for 40 ticks (20 before + 20 after triggering the parse call in a sibling Fiber).

### Row (e) — control, `flags: 0` (today's `rb_thread_call_without_gvl`)

| Run | `blocking_operation_wait_calls` | `max_gap` (s) | `parse_duration` (s) |
|---|---|---|---|
| seed 48753 | 0 | 0.0613 | 0.0604 |
| seed 1 | 0 | 0.0596 | 0.0590 |
| seed 2 | 0 | 0.0556 | 0.0556 |
| seed 3 | 0 | 0.0597 | 0.0593 |
| seed 4 | 0 | 0.0586 | 0.0585 |

Hook never fires; `max_gap` ≈ `parse_duration` in every run — full reactor stall, matching the
known pre-#64 blocking signature.

### Row (f) — decisive, `RB_NOGVL_OFFLOAD_SAFE` set

| Run | `blocking_operation_wait_calls` | `max_gap` (s) | `parse_duration` (s) | gap as % of parse |
|---|---|---|---|---|
| seed 48753 | 1 | 0.0014 | 0.0604 | 2.3% |
| seed 1 | 1 | 0.0014 | 0.0588 | 2.4% |
| seed 2 | 1 | 0.0013 | 0.0533 | 2.4% |
| seed 3 | 1 | 0.0013 | 0.0556 | 2.3% |
| seed 4 | 1 | 0.0014 | 0.0567 | 2.5% |

Hook fires exactly once per call, every run; `max_gap` stays flat at ~1.3-1.4ms regardless of
`parse_duration` — the reactor does not stall.

### Root-fiber variant (not a formal row — quick manual check)

Called `Duckling::Native.parse_nogvl_offload` directly from the root fiber (no `Fiber.schedule`),
with a scheduler installed:

```
before (root fiber, scheduler set, no Fiber.schedule): calls=0
after root-fiber call: calls=0
```

The hook does not fire outside a fiber-scheduled call stack — consistent with how `Duckling.parse`
would actually be called inside a reactor (always from a scheduled Fiber).

## Track 1 — Ruby 4.0.5, real `async` gem (`test/spike_77_falcon_fiber_blocking_test.rb`)

`ASYNC_SCHEDULER_WORKER_POOL=true` set for all rows. Same ticker/parser structure as
`test/falcon_fiber_blocking_test.rb`; `allowance = max(TICK_INTERVAL + parse_duration * 0.5, 0.025)`.

| Row | `SPIKE_NATIVE_METHOD` | `SPIKE_USE_THREAD` | `max_gap` (s) | `parse_duration` (s) | `allowance` (s) | PASS |
|---|---|---|---|---|---|---|
| (a) baseline | `parse` | `1` | 0.0014 | 0.1545 | 0.0783 | **true** |
| (b) | `parse` | `0` | 0.1303 | 0.1292 | 0.0656 | **false** |
| (c) key, run 1 | `parse_nogvl_offload` | `0` | 0.0012 | 0.1228 | 0.0624 | **true** |
| (c) key, run 2 | `parse_nogvl_offload` | `0` | 0.0013 | 0.1270 | 0.0645 | **true** |
| (c) key, run 3 | `parse_nogvl_offload` | `0` | 0.0013 | 0.1190 | 0.0605 | **true** |
| (c) key, run 4 | `parse_nogvl_offload` | `0` | 0.0013 | 0.1330 | 0.0675 | **true** |
| (d) sanity | `parse_nogvl_offload` | `1` | 0.0012 | 0.1332 | 0.0676 | **true** |

Row (b) reconfirms #64's existing necessity absent the flag, on Ruby 4.0.5 too. Row (c) — the key
row — passes consistently across 4 repeats: the real `async`/`io-event` stack auto-offloads the
call via the flag alone, no Ruby-level Thread wrapper, once on Ruby 4.0.

## Correctness regression check

`test/duckling_test.rb` + `test/duckling_comma_list_test.rb`, run with
`Duckling::Native.parse` aliased to call `parse_nogvl_offload`:

| Ruby version | Runs | Assertions | Failures | Errors |
|---|---|---|---|---|
| 3.4.10 | 9 | 55 | 0 | 0 |
| 4.0.5 | 9 | 55 | 0 | 0 |

No correctness regression from the alternate FFI dispatch on either Ruby version tested.

## Gotcha encountered while running this spike

`rake compile` installs the compiled artifact to a single shared `lib/duckling/duckling.bundle`
path regardless of Ruby version (there is no per-Ruby-version install path in this gem's build,
unlike the per-Ruby-version `tmp/<platform>/duckling/<ruby-version>/` build directories `rb_sys`
does maintain internally). Switching `RBENV_VERSION` without re-running `rake compile` first loads
whichever Ruby version's binary was last installed there, which — being a genuine ABI mismatch
between Ruby major/minor versions — surfaced as a confusing `TypeError: no implicit conversion of
Time into Time` rather than a load error. Always re-`compile` immediately after switching
`RBENV_VERSION`, before running anything directly (`rake test`'s `task test: :compile`
prerequisite already does this automatically).
