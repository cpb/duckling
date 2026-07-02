# Test-and-CI Mechanics for `falcon_fiber_blocking_test.rb`

Terrain map for issue #57 ("stop `Duckling.parse` from blocking sibling
Fibers in an async reactor"). This document covers how the hill-first failing
test (`test/falcon_fiber_blocking_test.rb`) and its new dev-dependency
(`async ~> 2.41`) interact with the rest of the repo's build/CI/dev-workflow
tooling, so an implementation PR fixing the GVL-blocking behavior doesn't get
surprised by unrelated CI failures. This is a documentation-only research
artifact — no application code was changed to produce it.

## 1. The test itself

`test/falcon_fiber_blocking_test.rb` is a single Minitest test,
`FalconFiberBlockingTest#test_duckling_parse_does_not_stall_other_fibers_in_async_reactor`,
that empirically tests the claim (first raised as "PLAUSIBLE" in
[the FFI risk analysis](../../../1-ship-duckling-gem-time-extraction-via-magnus-wafer/research/ffi-risks.md))
that `Duckling.parse` — a synchronous Rust FFI call that does not release the
GVL — stalls every other Fiber sharing the same `Falcon`/`async`-gem reactor
thread for the duration of the call. This differs from Puma's OS-thread
model, where the GVL is contended but the scheduler can still preempt
between bytecode instructions; an `async` reactor cooperatively schedules
Fibers on a single OS thread, so a native call that never yields to the
reactor freezes every sibling Fiber on that thread for its full duration.

### Structure

- **Constants**: `TICK_INTERVAL = 0.001` (1ms) — how often the "ticker"
  Fiber is asked to wake up. `NON_BLOCKING_TOLERANCE = 0.010` (10ms) — how
  much a tick gap is allowed to exceed `TICK_INTERVAL` before it's
  considered "blocked"; the pass condition is `max_gap < TICK_INTERVAL +
  NON_BLOCKING_TOLERANCE`, i.e. `max_gap < 0.011s`. `TICKS_BEFORE_PARSE =
  20` and `TICKS_AFTER_PARSE = 20` — the ticker records 20 gaps before the
  parser Fiber starts its call and 20 after, so there's a "normal" baseline
  on both sides of the parse window.
- **`LONG_PARAGRAPH` fixture**: a few hundred words of travel-itinerary
  prose containing a mix of dates, times, durations, numbers, and money
  amounts, chosen (per the test's own comments) to give `Duckling.parse`
  "realistic entity-extraction work to do (not just a cheap no-match scan)"
  and to match the "long LLM-generated paragraph" shape referenced in the
  FFI risk analysis (~3ms estimated parse time — the risk doc's Criterion
  benchmark for "long prose" measured ~2.93ms in a release build).
- **Warm-up call**: `Duckling.parse("tomorrow", ...)` is called once,
  outside the timed `Sync` block, specifically to absorb `Duckling.parse`'s
  first-call-per-process cost (lazy-static/regex compilation) so the timed
  run only measures steady-state request-handling latency.
- **Measurement**: uses `Process.clock_gettime(Process::CLOCK_MONOTONIC)`
  throughout (not `Time.now`), which is the correct choice for interval
  measurement since it's immune to wall-clock adjustments (NTP slew, system
  clock changes) that would otherwise corrupt gap measurements.
- **Mechanics**: inside a `Sync do ... end` block, an `Async` "ticker" task
  loops `TICKS_BEFORE_PARSE + TICKS_AFTER_PARSE` times, each iteration doing
  `task.sleep(TICK_INTERVAL)` and recording the gap since the last tick. A
  second `Async` "parser" task sleeps until the ticker has established its
  baseline (`TICK_INTERVAL * TICKS_BEFORE_PARSE`), then makes a single
  `Duckling.parse(LONG_PARAGRAPH, ...)` call and records its wall-clock
  duration. `dims:` is intentionally omitted from the call — the test's
  comment notes only the `"time"` dimension is implemented as of this gem
  version, so omitting `dims:` exercises the same code path `dims:
  ["time"]` would. After both tasks finish, the test asserts `max_gap <
  0.011s`; on failure, the assertion message reports both the max observed
  gap and the measured parse duration side by side, since a max gap
  approximately equal to the parse duration is exactly the failure
  signature the blocking-FFI-call hypothesis predicts.

### Reproduction

Ran `bundle exec ruby -I test -I lib test/falcon_fiber_blocking_test.rb`
against this branch (after `bundle install` and `bundle exec rake compile`,
neither of which had been run yet in this checkout). Result:

```
1) Failure:
FalconFiberBlockingTest#test_duckling_parse_does_not_stall_other_fibers_in_async_reactor
Expected 0.11061999999219552 to be < 0.011.
```

Max observed ticker gap **0.1106s**, measured `Duckling.parse` duration
**0.1098s** — the two numbers track each other closely, as predicted. This
is the same failure signature already reported in the task background (max
gap 0.278s vs. parse duration 0.277s from an earlier run) — the absolute
numbers differ run to run (plausibly due to machine load, thermal
throttling, or a debug- vs release-profile Cargo build — this checkout had
no prior `lib/duckling/duckling.bundle`, so `rake compile` built fresh), but
the order of magnitude and the tight coupling between "max gap" and "parse
duration" match. This is the currently-failing hill-first test issue #57
exists to turn green.

## 2. The new dev-dependency (`async`)

`duckling.gemspec` declares:

```ruby
spec.add_development_dependency "async", "~> 2.41"
```

with a comment clarifying it's "used only by
`test/falcon_fiber_blocking_test.rb` ... not a runtime dependency of the gem
itself." This is confirmed as correctly reflected in `Gemfile.lock`: `bundle
check` (before this research's `bundle install`) reported only `io-event
(1.19.1)` as missing — a resolution mismatch between the locked version and
what was already gem-installed locally in this dev environment, not a
lockfile/gemspec inconsistency. After `bundle install`, `bundle check`
reports the bundle satisfied, and `Gemfile.lock`'s `DEPENDENCIES` section
lists `async (~> 2.41)`, resolved to `async (2.41.0)`.

### Transitive dependencies (verified against `Gemfile.lock`)

`async (2.41.0)` pulls in, per the lockfile:

- `console (~> 1.29)` → resolved `console (1.36.0)`, itself depending on
  `fiber-annotation`, `fiber-local (~> 1.1)`, `json`
- `fiber-annotation` → resolved `fiber-annotation (0.2.0)`
- `io-event (~> 1.11)` → resolved `io-event (1.19.1)`
- `metrics (~> 0.12)` → resolved (present in lockfile as a `metrics`
  dependency of `async`)
- `traces (~> 0.18)` → resolved (present in lockfile as a `traces`
  dependency of `async`)
- `fiber-local (1.1.0)` → depends on `fiber-storage`
- `fiber-storage (1.0.1)`

All of these are published under the [socketry](https://github.com/socketry)
GitHub organization (same org as `async` itself:
[socketry/async](https://github.com/socketry/async), tag
[`v2.41.0`](https://github.com/socketry/async/tree/v2.41.0)).

### Native-extension check — the one dependency that matters for CI

Checked every transitive gem's installed `Gem::Specification#extensions`
and `#platform` directly (`ruby -e "Gem::Specification.find_by_name(...)"`)
rather than guessing:

| Gem | Platform | Extensions |
|---|---|---|
| `async` | `ruby` | none |
| `console` | `ruby` | none |
| `fiber-annotation` | `ruby` | none |
| `fiber-local` | `ruby` | none |
| `fiber-storage` | `ruby` | none |
| `metrics` | `ruby` | none |
| `traces` | `ruby` | none |
| **`io-event`** | **`ruby`** | **`["ext/extconf.rb"]`** |

**`io-event` is the only gem in this dependency chain with a native C
extension.** It is shipped as a source gem (`platform: ruby`, not a
precompiled per-platform binary gem), so it compiles via `mkmf` at install
time on every platform. Its
[`ext/extconf.rb`](https://github.com/socketry/io-event/blob/v1.19.1/ext/extconf.rb)
(pinned to the locked version's tag,
[`v1.19.1`](https://github.com/socketry/io-event/tree/v1.19.1)) builds a
selector backend appropriate to the host:

- `sys/epoll.h` present → compiles the epoll selector (Linux)
- `sys/event.h` present → compiles the kqueue selector (macOS/BSD)
- `liburing.h` **and** `liburing` present → additionally compiles the
  `io_uring` selector, but this check is wrapped in `if have_library("uring")
  and have_header("liburing.h")` — it silently degrades to epoll/kqueue when
  absent, rather than failing the build.

So `io-event` needs a standard C compiler + `make` at gem-install time (no
`liburing`, no other special headers), which is already a baseline
assumption for this repo — Ruby MRI's own gem ecosystem (and this gem's own
native extension, wired via `rb_sys`/Cargo) already requires a C toolchain
on any machine that builds it. This introduces no requirement beyond what
`ubuntu-latest` GitHub Actions runners and the Claude Code Web sandbox
already provide.

## 3. CI matrix impact

`.github/workflows/main.yml` runs a single-entry Ruby matrix (`3.3.6`) on
`ubuntu-latest`. Relevant steps, in order: `actions/checkout`, `ruby/setup-ruby`
(with `bundler-cache: true`, `ruby-version: 3.3.6`), `dtolnay/rust-toolchain`
(pinned `1.94.1`, with `clippy`/`rustfmt`), `cargo fmt --check`, `cargo
clippy -- -D warnings` (both against `ext/duckling/`), then `bundle exec
rake` (which runs `standard` + `compile` + `test` — the full Minitest suite,
now including `falcon_fiber_blocking_test.rb`).

**`bundler-cache: true` already covers `async` and its transitive deps with
no extra CI steps.** `ruby/setup-ruby`'s `bundler-cache: true` option runs
`bundle install` (and caches the result keyed on the lockfile hash), which
resolves and installs every gem in `Gemfile.lock`, including `async` and
`io-event`. Since `io-event`'s native extension only needs a C
compiler/`make` — both present on the standard `ubuntu-latest` runner image
(used for many other gems' native extensions across the Ruby ecosystem,
same as this gem's own Rust extension needs a Rust toolchain) — no
additional `apt-get install` or runner-configuration step is required.

Cross-referenced this against how [duckling](https://github.com/wafer-inc/duckling)'s
upstream dependency, [socketry/async](https://github.com/socketry/async)
itself, tests things in its own CI, to check for any hidden runner
requirement this repo's CI doesn't already satisfy:

- [`async`'s main test workflow](https://github.com/socketry/async/blob/v2.41.0/.github/workflows/test.yaml)
  (pinned to the `v2.41.0` tag, matching the version this repo locks) runs
  on `ubuntu-latest` and `macos-latest` across several Ruby versions using
  nothing but `actions/checkout` + `ruby/setup-ruby` with
  `bundler-cache: true` + `bundle exec bake test`. No extra system packages,
  no `io_uring`/epoll-specific runner configuration.
- `async`'s repo *does* have a separate
  [`test-uring.yaml`](https://github.com/socketry/async/blob/v2.41.0/.github/workflows/test-uring.yaml)
  workflow that explicitly sets `IO_EVENT_SELECTOR=URing` and runs
  `sudo apt-get install -y liburing-dev` before testing — but this only
  exists to specifically exercise the optional `io_uring` selector path.
  This repo's CI does not set `IO_EVENT_SELECTOR` and does not install
  `liburing-dev`, so `io-event` will silently fall back to the epoll
  selector on the `ubuntu-latest` runner (matching `extconf.rb`'s graceful
  degradation described in section 2) — which is exactly what
  `falcon_fiber_blocking_test.rb` needs, since the test doesn't care which
  selector backend `Async` uses under the hood.

**Conclusion: no CI matrix or workflow change is needed** for the `async`
dependency to work in `.github/workflows/main.yml` as currently written.

One unrelated, pre-existing, non-blocking wrinkle: `Gemfile.lock`'s
`PLATFORMS` section currently lists only `ruby` and `x86_64-darwin-24` (this
developer's local platform) — not `x86_64-linux` (the `ubuntu-latest`
runner's platform). Since every gem this dependency chain touches resolves
to the platform-independent `ruby` variant (see the table above — no gem
needs a platform-specific binary), and neither `Gemfile` nor CI sets
`BUNDLE_FROZEN`/`BUNDLE_DEPLOYMENT` (checked: no `.bundle/config` file and no
such env var set in `main.yml`), a plain `bundle install` on the runner
transparently resolves for its own platform without erroring — this is a
pre-existing lockfile characteristic unrelated to the `async` addition and
was already reproduced as passing after `bundle install` in this research.

## 4. Claude Code Web JIT dependency install path

`bin/claude-web-deps.sh` (sourced by both `bin/test`'s no-arg path and
`bin/claude-code-web-setup`'s Edit/Write-gated hook) defines two functions:

- `install_gems`: hashes `Gemfile.lock`, checks for a receipt file at
  `tmp/claude-web-receipts/gems-<hash>`, and if absent, runs a plain
  `bundle install` before touching the receipt.
- `compile_extension`: hashes the Rust extension's source files
  (`*.rs`/`*.toml`/`*.lock`/`extconf.rb` under `ext/duckling`), and if the
  corresponding receipt is absent, runs `bundle exec rake compile`.

**This script is fully dependency-agnostic and needs no change for
`async`.** `install_gems` doesn't special-case which gems are in
`Gemfile.lock` — it just runs `bundle install` generically, and its
cache-invalidation key is the lockfile's own content hash. Since adding
`async ~> 2.41` to `duckling.gemspec` changed `Gemfile.lock`'s contents
(hence its hash), any prior receipt for an older lockfile hash is
automatically invalidated on the next `bin/test`/hook invocation in a Claude
Code Web session, forcing a fresh `bundle install` that picks up `async` and
its transitive deps with zero special-casing required. `compile_extension`
is scoped only to the Rust extension's own source files and is unaffected
by a Ruby-only dependency change.

## 5. `bin/lint` / StandardRB

Ran `bundle exec standardrb test/falcon_fiber_blocking_test.rb
duckling.gemspec` directly (the same tool `bin/lint` invokes via
`bundle exec standardrb --fix` on `.rb` files, and the same tool CI's
`bundle exec rake` runs as the `standard` task). **No output — meaning zero
offenses.** Both `test/falcon_fiber_blocking_test.rb` (as already committed
via issue #38's branch) and the gemspec's new
`spec.add_development_dependency "async", "~> 2.41"` line pass StandardRB
cleanly as currently written. `bin/lint`'s Rust branch is irrelevant here
since neither of these files is a `.rs` file. A future implementation PR
touching only `ext/duckling/src/*.rs` (the likely site of the actual GVL
fix — e.g. wrapping the `duckling::parse` FFI call with Magnus's
`without_gvl`) would instead trip `bin/lint`'s `rustfmt` +
`cargo clippy --fix` path, not StandardRB — worth knowing, but out of scope
for this Ruby-side test-and-CI-mechanics research.

## What needs to change, if anything, before an implementation PR can rely on this test passing in CI

**Nothing.** The test file and its `async` dev-dependency are already fully
CI-compatible as committed on this branch:

- `Gemfile.lock` already reflects `async ~> 2.41` correctly; `bundle check`
  is clean after `bundle install`.
- The only native extension in the new dependency chain (`io-event`) needs
  nothing beyond a C compiler + `make`, both already present on
  `ubuntu-latest` and assumed by this repo's existing Rust-extension build.
  Its optional `io_uring` backend gracefully no-ops without `liburing-dev`,
  which this repo's CI correctly doesn't install (nor does it need to).
- `ruby/setup-ruby`'s existing `bundler-cache: true` step in
  `.github/workflows/main.yml` handles installing `async` and its
  transitive deps automatically — no new CI step, no new `apt-get install`,
  no matrix change required.
- `bin/claude-web-deps.sh`'s `install_gems` is lockfile-hash-keyed and
  already picks up the new dependency with no code change.
- `test/falcon_fiber_blocking_test.rb` and the gemspec's new dependency
  line both pass `standardrb` (`bin/lint`'s Ruby-side tool) cleanly today.

The only thing standing between this branch and a green CI run on this test
is the actual GVL fix itself (issue #57's real scope) — once
`Duckling.parse` stops holding the GVL for the duration of its native call
(e.g. via Magnus's GVL-release mechanism around the FFI boundary), this test
should pass in CI exactly as it does — or doesn't — locally, with no
additional test-and-CI-mechanics surprises from the `async` dependency or
the CI matrix.

## Open follow-ups

- `Gemfile.lock`'s `PLATFORMS` list doesn't include `x86_64-linux` (only
  `ruby` and this developer's `x86_64-darwin-24`). This is pre-existing and
  currently harmless (see section 3), but if a future dependency ever
  *does* ship platform-specific binary variants, an explicit
  `bundle lock --add-platform x86_64-linux` (mirroring what CI actually
  runs on) would be the more robust fix rather than continuing to rely on
  bundler's implicit non-frozen auto-resolution.
- The measured wall-clock numbers in this test (both the task's cited
  0.278s/0.277s run and this research's own 0.1106s/0.1098s run) vary by
  roughly 2-3x between runs on presumably similar hardware. Section 1 notes
  a plausible cause (dev vs. release Cargo profile / machine load) but this
  wasn't independently isolated — not blocking for issue #57 (the test's
  *pass/fail* threshold is what matters, not the absolute duration), but
  worth knowing if a future PR wants to add stricter latency budgets.
