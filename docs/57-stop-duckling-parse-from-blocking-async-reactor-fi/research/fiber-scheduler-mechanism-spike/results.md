# Raw measurements

Every row is a run of `test/falcon_fiber_blocking_test.rb` (the pre-existing
failing test from issue #38/#57 — see
[Fiber-Scheduler Mechanism Spike](README.md#test-fixture) for what it measures). `max_gap` is the
largest observed wall-clock gap between successive ticks of the sibling
"ticker" `Fiber`; `parse_duration` is the wall-clock time the single
`Duckling.parse` call itself took. The test's pass threshold is
`max_gap < 0.011s` (`TICK_INTERVAL` 0.001s + `NON_BLOCKING_TOLERANCE` 0.010s).

All runs below used `bundle exec ruby -I test test/falcon_fiber_blocking_test.rb`
on macOS (x86_64-darwin24), with `ext/duckling/` compiled via
`bundle exec rake compile`. "release" is Cargo's `release` profile (what CI
and `rake release` build); "dev" is the `RB_SYS_CARGO_PROFILE=dev` profile
`bin/setup` seeds locally (see `AGENTS.md`'s "Build and test commands").

## Baseline: unmodified Duckling.parse, calls duckling_parse directly, GVL held throughout

| Ruby | Profile | Result | max_gap (s) | parse_duration (s) |
|---|---|---|---|---|
| 3.3.6 | release | FAIL | 0.1363 | 0.1361 |
| 3.3.6 | dev | FAIL | 1.5494 | 1.5485 |
| 3.3.6 | dev | FAIL | 1.4451 | 1.4450 |

`max_gap` tracks `parse_duration` almost exactly in every run — the
blocking-FFI-call claim the test was written to falsify/confirm is
confirmed. The dev-profile runs are ~10x slower than release because
[duckling](https://github.com/wafer-inc/duckling) leans on `regex` matching
across many compiled patterns, which optimizes heavily under LLVM; the
absolute numbers vary by profile and machine, but the *shape* (gap ≈
duration) is what matters and is stable across both.

## Approach A alone: rb_thread_call_without_gvl around duckling_parse, no Ruby-level Thread spawn

Native `parse` wraps just the `duckling_parse(...)` call in
`rb_sys::rb_thread_call_without_gvl`, invoked directly on the calling
Fiber's thread (see README for the exact code shape).

| Ruby | Profile | Result | max_gap (s) | parse_duration (s) |
|---|---|---|---|---|
| 3.3.6 | release | FAIL | 0.1264 | 0.1261 |
| 3.3.6 | release | FAIL | 0.1237 | 0.1229 |
| 3.3.6 | release | FAIL | 0.1327 | 0.1321 |
| 3.3.6 | release | FAIL | 0.1221 | 0.1211 |
| 3.3.6 | release | FAIL | 0.1277 | 0.1272 |
| 3.3.6 | release | FAIL | 0.1167 | 0.1156 |
| 3.4.5 | release | FAIL | 0.1107 | 0.1095 |
| 3.4.5 | release | FAIL | 0.1029 | 0.1027 |
| 3.4.5 | release | FAIL | 0.1095 | 0.1090 |

Still fails on **both** Ruby versions — including 3.4.5, which has
`Fiber::Scheduler#blocking_operation_wait`. See the README's "Why Approach A
alone isn't enough" section for the precise, source-verified reason the 3.4
hook never fires here.

## Approach B alone: background Thread, but GVL not released in the native call

Isolates the other half: `Duckling.parse` spawns `Thread.new { native_call
}.value`, but the native call still runs `duckling_parse` directly (no
`rb_thread_call_without_gvl`), so it holds the GVL for the whole call
duration, just on a second OS thread instead of the calling thread.

| Ruby | Profile | Result | max_gap (s) | parse_duration (s) |
|---|---|---|---|---|
| 3.3.6 | release | FAIL | 0.1297 | 0.1297 |
| 3.3.6 | release | FAIL | 0.1078 | 0.1070 |
| 3.3.6 | release | FAIL | 0.1055 | 0.1055 |

Also fails — a bare `Thread.new { ... }.value` wrapper is not sufficient on
its own either. See README's "Why Approach B alone isn't enough".

## Approach A+B combined: rb_thread_call_without_gvl and a spawned background Thread

Both changes together: `Duckling.parse` spawns
`Thread.new { _native_parse_spike(...) }.value`, and the native call
releases the GVL via `rb_thread_call_without_gvl` around `duckling_parse`.

| Ruby | Profile | Result | max_gap (s) | parse_duration (s) |
|---|---|---|---|---|
| 3.3.6 | release | PASS | 0.0012 | 0.1296 |
| 3.3.6 | release | PASS | 0.0012 | 0.1210 |
| 3.3.6 | release | PASS | 0.0013 | 0.1176 |
| 3.3.6 | release | PASS | 0.0014 | 0.1113 |
| 3.3.6 | release | PASS | 0.0014 | 0.1097 |
| 3.3.6 | release | PASS | 0.0014 | 0.1089 |
| 3.3.6 | release | PASS | 0.0016 | 0.1174 |
| 3.3.6 | release | PASS | 0.0014 | 0.1120 |
| 3.4.5 | release | PASS | 0.0013 | 0.1124 |
| 3.4.5 | release | PASS | 0.0013 | 0.1113 |
| 3.4.5 | release | PASS | 0.0013 | 0.1092 |

Passes consistently (11/11 runs across both Ruby versions), with `max_gap`
roughly two orders of magnitude below the parse duration and comfortably
under the `0.011s` threshold, while `parse_duration` itself is essentially
unaffected — the fix does not change how long the parse takes, only whether
sibling `Fiber`s can make progress while it runs.

Existing correctness tests (`test/duckling_test.rb`,
`test/duckling_comma_list_test.rb`) were re-run against every prototype
variant above and stayed green throughout — the GVL-release/Thread-spawn
mechanism did not change `Duckling.parse`'s return values.
