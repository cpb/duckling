# AGENTS.md

Orientation for AI agents working in this repo. Read this before doing
exploratory reads — it should answer "where does X live" and "how do I build
the extension" without you having to re-derive them.

## What this is

`duckling` is a Ruby gem that wraps the Rust [`wafer-inc/duckling`](https://github.com/wafer-inc/duckling)
NER/entity-extraction engine via [Magnus](https://github.com/matsadler/magnus)
and `rb-sys`, so Ruby code can extract entities (times, numbers, money,
emails, etc.) without running a separate HTTP service.

**Current state:** the Ruby API surface (`lib/duckling.rb`), gemspec, Rakefile, and native extension are all built and live. Precompiled binary gems for `x86_64-linux`/`x86_64-darwin` are now published alongside the source gem — see "Build model" under "Rust/Magnus wiring" and "Gem release conventions" below. If you notice this file describing a not-yet-built piece as current, or vice versa, fix it in the same PR (see "Keeping this file current").

## Directory layout

| Path | Purpose |
|---|---|
| `ext/duckling/` | Native Rust extension. Holds `extconf.rb` (build wiring), `Cargo.toml` (crate config), and `src/` (Rust source). See "Rust/Magnus wiring" below. |
| `lib/duckling.rb` | Ruby module entrypoint. `require_relative "duckling/duckling"` loads the compiled native extension, which defines `Duckling::Native.parse` (the raw entrypoint — no thread spawn). `Duckling.parse` is then defined here as a thin Ruby-level wrapper that only dispatches through `Thread.new { Native.parse(...) }.value` when `Fiber.scheduler` is installed on the calling thread — see the "Rust/Magnus wiring" section's GVL-release bullet below for why a bare GVL release alone isn't sufficient for a Fiber to yield, and why plain thread-pool callers skip the thread spawn entirely. |
| `lib/duckling/version.rb` | `Duckling::VERSION` constant — single source of truth for the gem version, read by `duckling.gemspec` and (once built) the release pipeline. |
| `test/` | Minitest suite. `test_helper.rb` sets up the load path and requires `minitest/autorun`; test files currently follow `<name>_test.rb` / `class <Name>Test < Minitest::Test` naming. |
| `bin/` | Two kinds of scripts living side by side — see "bin/ scripts" below. Don't confuse the dev-workflow scripts (`worktree`, `check-worktree`, `claude-code-web-setup`, `lint`) with the gem's own build/test entrypoints (`setup`, `console`, `test`, `benchmark`). |
| `benchmark/` | `benchmark-ips`-based suite exercising `Duckling.parse` (`parse_benchmark.rb`: ips + GC/allocation pressure + threaded-concurrency scenarios) and the environment-aware recording/reporting logic (`report.rb`: writes `docs/benchmarks/<environment>/<version>.json`, regenerates `docs/benchmarks/README.md`). Not part of what ships in the gem (excluded from packaging in `duckling.gemspec`) or of `task default:` (too slow/non-deterministic for every `bundle exec rake`). Run via `bin/benchmark` — see "Build and test commands" below. |
| `docs/benchmarks/` | Per-environment, per-version benchmark history: `<environment>/<version>.json` raw results plus an auto-generated `README.md` (owned entirely by `DucklingBenchmark::Report.write_docs_readme!` — never hand-edited) with Mermaid charts comparing environments. Also holds `comparison-artifact-prompt.md`, a hand-maintained saved prompt (not auto-generated) for regenerating a richer interactive HTML cross-version comparison artifact than the README's latest-per-environment view supports — re-run it as new versions get recorded or `-rc` data changes. Committed to git but excluded from the packaged gem. Linked from the root `README.md`'s "Performance" section. |
| `Brewfile` | Homebrew deps for local macOS dev: `rust` (bundles `cargo`/`rustc`/`rustfmt`/`clippy`), `hk` (see `hk.pkl` below — local-dev-only, not installed in CI or remote/web sessions), and `gh` (GitHub CLI, used by `benchmark:record_pr` to open PRs — needs `gh auth login` before that task can push/open a PR). `bin/setup` runs `brew bundle` against it, then `hk install`, when Homebrew is present. |
| `duckling.gemspec` | Gem spec. Declares `spec.extensions = ["ext/duckling/extconf.rb"]` (the native-extension build entrypoint), depends on `rb_sys` and dev-depends on `rake-compiler` + `benchmark-ips` — see the gemspec's `add_dependency`/`add_development_dependency` lines for the current version constraints. Packaged files come from `git ls-files`, excluding `bin/`, `Gemfile`, `.gitignore`, `.env.local.example`, `test/`, `.github/`, `.standard.yml`, `hk.pkl`, `benchmark/`, `docs/benchmarks/`. |
| `Rakefile` | `task default: %i[standard compile test]` — runs StandardRB lint, compiles the Rust extension, then Minitest. `test` also declares an explicit `task test: :compile` prerequisite (`Minitest::TestTask` has no built-in way to express this itself), so `bundle exec rake test` run in isolation still compiles first — not just `bundle exec rake` via the `default` array's ordering. Loads `.env.local` via `Dotenv.load` at the top (no-ops if absent, e.g. in CI); also defines an opt-in `:dev` task (not part of `default`) that sets `RB_SYS_CARGO_PROFILE=dev` directly — use `bundle exec rake dev compile test` for a one-off dev-profile build without `.env.local` in place. Also defines `benchmark` / `benchmark:record` / `benchmark:record_pr` (all deliberately excluded from `task default:`) — see "Build and test commands" below for how they relate. |
| `.env.local.example` | Tracked template for `.env.local` (gitignored) — sets `RB_SYS_CARGO_PROFILE=dev` so `bin/setup` (see below) makes the dev Cargo profile the local default. |
| `.standard.yml` | StandardRB config — see its `ruby_version:` field for the Ruby version StandardRB targets. StandardRB wraps RuboCop internally; there is no separate `.rubocop.yml`. |
| `hk.pkl` | `hk` config (StandardRB + rustfmt + clippy via `hk`'s builtin steps) — scoped to local dev only. `bin/setup` installs `hk` (via `Brewfile`) and runs `hk install` to wire up a `git commit` pre-commit hook from this config. Neither `bin/lint` (the cpb-harness PostToolUse hook) nor CI shell out to `hk` — both run the same underlying tools directly instead, since `hk`'s Pkl config needs to fetch its schema package from a GitHub release on every invocation, which isn't reliable in sandboxed/network-restricted environments (CI, remote/web sessions). **Git stash merge gotcha**: when resolving merge conflicts, `git stash` (used by `hk`'s pre-commit hook) unconditionally clears `.git/MERGE_HEAD`, which can silently downgrade a merge commit to a single-parent commit if any unstaged changes remain. **Workaround**: bypass the hook for merge-resolution commits with `HK=0 git commit ...` after manually running `standardrb --fix`/`rustfmt`/`cargo clippy --fix`. See `research-hk-stash-merge` on the wiki for full background. |
| `.github/workflows/main.yml` | CI: runs StandardRB lint, cross-platform Rust checks (`cargo fmt --check`, `cargo clippy -- -D warnings` against `ext/duckling/`), then `bundle exec rake`. A 4-entry matrix includes `"Ruby 3.3.6"` (the baseline, pinned to Claude Code Web sandbox Rust version), plus three forward-compat signal entries allowed to fail. Branch protection on `main` requires only the baseline entry to pass. Runs for every push to `main` and every PR. |
| `.github/workflows/release.yml` | Tag-triggered release workflow. Gates on CI, then runs cross-compilation and benchmarking in parallel. Builds the `ruby` source gem and pushes it with `x86_64-linux`/`x86_64-darwin` binary gems to RubyGems, then cuts a GitHub release. See "Gem release conventions" below. |
| `.github/workflows/cross-gem.yml` | Reusable workflow that cross-compiles the native extension for `x86_64-linux` and `x86_64-darwin` via Docker containers bundling their own Rust + cross-toolchain. Called from `release.yml` for releases; trigger manually with `gh workflow run cross-gem.yml --ref <branch>` to smoke-test cross-compilation. |
| `.github/workflows/benchmark.yml` | Reusable workflow that compiles the native extension and records a `docs/benchmarks/github-actions/<version>.json` data point via `bundle exec rake benchmark:record_pr`. Called from `release.yml` in parallel with cross-compilation. Also standalone-dispatchable via `gh workflow run benchmark.yml --ref <branch>` to populate benchmark data without releasing. |
| `.github/workflows/benchmark-branch.yml` | Records a benchmark data point for the current branch's own code, committing/pushing straight back to that branch (unlike `benchmark.yml`, which always branches off `origin/main`). For capturing data points that reflect unmerged PR branches. Standalone `workflow_dispatch` only. |
| `.github/scripts/apply-tag-ruleset.sh` | Idempotent `gh api` script that creates/updates the GitHub tag ruleset restricting `v*.*.*` tag creation/update to repo admins. Source of truth for that ruleset's config — re-run it to change the config rather than editing it by hand in the GitHub UI. |

## Build and test commands

- **`bin/setup`** — runs `brew bundle` (installing the Rust toolchain and `hk` per `Brewfile`) and `hk install` (wiring up the local `git commit` pre-commit hook from `hk.pkl`) when Homebrew is present, then `bundle install`, then (if `.env.local` doesn't already exist, and `CI` isn't `true`) copies `.env.local.example` to `.env.local`, which sets `RB_SYS_CARGO_PROFILE=dev`. No-ops the Homebrew step gracefully on machines without `brew` (e.g. CI runners and remote/web sessions, which never install or need `hk` — see `hk.pkl` above), and skips the `.env.local` seed entirely in CI regardless (which always wants the release profile). Run this first in a fresh checkout/worktree.
- **`bin/console`** — loads the gem and drops you into IRB for interactive experimentation.
- **`bin/test [file:line]`** — routes through `bundle exec rake test` (not a raw `ruby -I test` invocation), so the Rakefile's `task test: :compile` prerequisite guarantees the extension is compiled first. `Minitest::TestTask` takes no CLI args directly, so arguments are "massaged" into the env vars it reads: a single `path/to/file.rb:LINE` ref (the `bin/worktree heal-reproduce` contract) is resolved to the nearest preceding `def test_*` method at/above that line and passed as `N=<name>` (`-i`/`--include`, exact method-name match); anything else passes through verbatim as `A="..."` (raw extra args, e.g. `-i test_foo`, `-v`, `--seed 123`). With no arguments, runs the full suite via `bundle exec rake` instead. In a remote Claude Code Web session (`CLAUDE_CODE_REMOTE=true`), it first JIT-installs gems via `bin/claude-web-deps.sh` (compiling the extension is no longer needed here — `bundle exec rake test` compiles it via the `:compile` prerequisite), since a bare Bash call doesn't trigger the Edit/Write-gated `bin/claude-code-web-setup` PreToolUse hook.
- **`bin/lint`** — the cpb-harness PostToolUse hook, invoked after every Edit/Write with `$CLAUDE_FILE_PATHS`, including in remote/web sessions. Splits the changed paths by extension and auto-fixes them directly with the same tools CI runs (`bundle exec standardrb --fix` for `.rb` files, `rustfmt` + `cargo clippy --fix` against `ext/duckling/Cargo.toml` for `.rs` files) — it does not shell out to `hk` (see `hk.pkl` above), so no `hk` provisioning is needed for this hook to work anywhere, including remote/web sessions. Requires `standardrb` (via `bundle install`) and `rustfmt`/`cargo clippy` (rustup components) on `PATH`.
- **`rake` / `bundle exec rake`** — default task: `standard` (StandardRB lint) + `compile` (builds the Rust extension via `RbSys::ExtensionTask`) + `test` (Minitest).
- **Compiling the native extension**: `rake compile` (via `RbSys::ExtensionTask`, wired in the `Rakefile`) builds `ext/duckling/` and places the compiled artifact under `lib/duckling/`. After `bin/setup` has run, this builds Cargo's `dev` profile locally (faster compile, slower runtime) because `.env.local` sets `RB_SYS_CARGO_PROFILE=dev` and the Rakefile loads it via `Dotenv.load(".env.local")`. `.env.local` is gitignored and never present in CI, so `bundle exec rake` in CI (`main.yml`) and `rake release` always build the optimized `release` profile regardless of this.
- **`rake dev compile test`** — explicit one-off dev-profile build via the `:dev` task, for use without `.env.local` in place (e.g. before running `bin/setup`, or in an environment where you don't want it seeded).
- **`rake 'native_gem[x86_64-linux]'` / `rake 'native_gem[x86_64-darwin]'`** — cross-compiles a precompiled binary gem for the given platform locally via `bundle exec rb-sys-dock --platform <platform> --ruby-versions 3.2 --build`, the same command `.github/workflows/cross-gem.yml` runs in CI. Requires Docker (not just Rust) — `rb-sys-dock` builds inside the `rbsys/<platform>` container images, which bundle their own Rust + cross-toolchain (including osxcross for darwin), so this works on a Linux dev machine too. Not part of `task default`; only needed when debugging the cross-compile pipeline itself.
- **`bin/benchmark`** — thin wrapper around the `benchmark`/`benchmark:record`/`benchmark:record_pr` Rake tasks (below), matching `bin/test`'s `CLAUDE_CODE_REMOTE` JIT-setup convention.
- **`rake benchmark`** — runs the `benchmark-ips` suite in `benchmark/parse_benchmark.rb` (ips + GC/allocation pressure + 10-thread concurrency scenarios) against a forced release-profile build (via the `:benchmark_env` task, which unsets `RB_SYS_CARGO_PROFILE` and reenables `:compile` regardless of a local `.env.local`); console output only, no files written. Not part of `task default:` — too slow (~25-30s) for every `bundle exec rake`.
- **`rake "benchmark:record"`** — runs `benchmark`, then writes `docs/benchmarks/<environment>/<version>.json` (environment auto-detected: `github-actions` if `GITHUB_ACTIONS=true`, `claude-code-web` if `CLAUDE_CODE_REMOTE=true`, else `local`; version from `Duckling::VERSION`) and regenerates `docs/benchmarks/README.md` from the full history.
- **`rake "benchmark:record_pr"`** — guarded by the existing `release:guard_clean` task (refuses to run against a dirty working tree); checks out a fresh branch off `origin/main`, runs `benchmark:record` there, commits, pushes, and opens+auto-merges a PR via `gh` — then restores the original branch. Meant to be run from three places: the tag-triggered release pipeline (`.github/workflows/release.yml`), a Claude Code Web session, and a local dev machine (needs `gh auth login`) — each contributes that environment's own data point via its own PR, independent of the CHANGELOG PR.

## Public and internal APIs

- **`Duckling.parse(text, locale: "en", dims: ["time"], reference_time: nil, with_latent: false)`** — the public Ruby API. This is a thin wrapper around `Duckling::Native.parse` that conditionally dispatches through `Thread.new { ... }.value` when a `Fiber.scheduler` is installed on the calling thread (important for async frameworks like Falcon). Plain thread-pool callers skip the thread spawn.
- **`Duckling::Native.parse(...)`** — the raw Magnus/native entrypoint. Called directly by `Duckling.parse` and by benchmarks. Releases the GVL around the underlying Rust parse call.
- **`Duckling::PanickingNativeFake`** — test-only mock for testing panic propagation. Not part of the public API; never use in production code.

## Test guide

The test suite covers several distinct concerns:

- **API shape and time entity behavior**: `test/duckling_test.rb` (basic parse structure, entity fields), `test/duckling_time_test.rb` (Time/DateTime parsing and locale handling).
- **Fiber scheduler dispatch**: `test/falcon_fiber_blocking_test.rb` (Fiber::Scheduler integration, thread-per-call behavior), `test/thread_pool_dispatch_test.rb` (plain thread-pool callers skip per-call thread spawn).
- **Panic/error propagation and stderr behavior**: `test/native_panic_test.rb` (panic handling), `test/parse_error_stderr_test.rb` (stderr output verification).
- **Benchmark report generation**: `test/benchmark_report_test.rb` (report.rb logic, environment detection, docs generation).

## Rust/Magnus wiring

- **Rust crate location**: `ext/duckling/` (crate name `duckling` — same name as the wrapped `duckling` crates.io dependency; this is fine since Cargo namespaces a package's own compile target separately from its dependency names, and extension code only ever references the dependency via `duckling::parse(...)`, never `crate::`-vs-`duckling::` ambiguity).
- **The wrapped crate**: `wafer-inc/duckling`, published on crates.io as `duckling` (pure-Rust deps: regex, chrono, serde, serde_json, once_cell, smallvec — no bindgen/libclang required); see `ext/duckling/Cargo.toml` for the pinned version constraint. Its main entrypoint is `duckling::parse(text, locale, dims, context, options) -> Vec<Entity>`; in release builds it wraps the parse in `catch_unwind` and returns `vec![]` on panic.
- **`extconf.rb` wiring**: `rb_sys/mkmf`'s `create_rust_makefile` ties Cargo into the Ruby `mkmf` build:
  ```ruby
  require "mkmf"
  require "rb_sys/mkmf"

  create_rust_makefile("duckling/duckling")
  ```
  The `"duckling/duckling"` argument controls the output path: the compiled artifact lands at `lib/duckling/duckling.bundle` (macOS) / `lib/duckling/duckling.so` (Linux), which is what `lib/duckling.rb` `require_relative`s.
- **`Cargo.toml`**: `cdylib` crate type, depends on `magnus` (`"0.8"`, with `features = ["chrono"]` — this is what makes `chrono::DateTime<FixedOffset>`/`NaiveDateTime` implement magnus's `IntoValue`/`TryConvert` at all, so a parsed time entity's `:value` can be handed to Ruby as a real `Time` object instead of a formatted string), the wrapped `duckling` crate (`"0.4"`), `chrono` (also a direct dependency in its own right, for `FixedOffset`/`TimeZone` in `src/lib.rs`), and `rb-sys` (`default-features = false, features = ["stable-api-compiled-fallback"]` — avoids needing libclang/bindgen on the build machine, and is also what makes single-binary-per-platform precompiled gems possible, see "Build model" below); see `ext/duckling/Cargo.toml` for exact version constraints.
  - **Do not use `magnus = "0.9"`** — despite what some early design docs assumed, 0.9 has never been published to crates.io (only 0.8.2 is released as of this writing); pinning `"0.9"` will fail to resolve. The 0.8.2 API creates symbols via `ruby.to_symbol("key")`, not the 0.9-only `ruby.sym("key")`. Everything else (scan_args, get_kwargs, function!, RHash::aset, Ruby::ary_new, hash_new, chrono FixedOffset IntoValue) is unchanged between 0.8.2 and 0.9. Before trusting a magnus API claim from design docs, spot-check it against the actual published source (`~/.cargo/registry/src/index.crates.io-*/magnus-0.8.2/`).
- **Build model**: ships as a `ruby` source gem plus precompiled `x86_64-linux` and `x86_64-darwin` binary gems (unversioned — RubyGems' darwin platform matching treats a `nil` OS version as a wildcard, so this installs on any Darwin major version including newer ones) — installers on those two platforms need no Rust toolchain. `Rakefile` uses `RbSys::ExtensionTask` (not plain `Rake::ExtensionTask`) with `ext.cross_compile = true` / `ext.cross_platform = ["x86_64-linux", "x86_64-darwin"]`; the actual cross-compilation happens in `.github/workflows/cross-gem.yml` via `oxidize-rb/actions/cross-gem`, which wraps `rb-sys-dock`/`rake-compiler-dock` and runs the Cargo build inside `rbsys/<platform>` Docker containers (bundling their own Rust + osxcross — no host Rust toolchain needed for cross-compiling). Because `rb-sys`'s `stable-api-compiled-fallback` feature targets Ruby's ABI-stable C API (3.2+), one binary per platform covers every Ruby minor version `duckling.gemspec`'s `required_ruby_version` allows — no per-Ruby-version fat gems. This is intentionally scoped to just these 2 platforms; expanding to the full 6-platform/9-platform matrices anticipated by earlier design docs (musl/arm variants, Windows, JRuby) is a deferred follow-up — extend by appending to `ext.cross_platform` and the `cross-gem.yml` matrix, nothing more structural should be needed.
- **GVL release + thread-per-call dispatch**: `Duckling::Native.parse` (the Magnus-defined singleton method) releases the GVL around the native `duckling::parse` call via the raw `rb_sys::rb_thread_call_without_gvl` FFI — Magnus 0.8.2 has no safe wrapper for this. Inputs/outputs crossing the off-GVL callback are carried in a `ParsePayload` struct holding only plain owned Rust data (no `magnus::Value`/`magnus::Error` — see the GC-safety gotcha below), and the callback wraps the native call in `std::panic::catch_unwind` unconditionally, since the wrapped `duckling` crate's own panic guard is compiled out under `#[cfg(debug_assertions)]` (i.e. absent from this repo's `dev`-profile local default). A caught panic surfaces to the caller as a rescuable `RuntimeError` (`ruby.exception_runtime_error()`, not magnus's own `Error::from_panic` convention of the unrescuable `fatal`), with the original panic message preserved. A bare GVL release is *not* sufficient to unblock an `Async::Reactor`-scheduled Fiber on its own (Ruby 3.4's `Fiber::Scheduler#blocking_operation_wait` needs a flag `rb_thread_call_without_gvl` never sets) — `Duckling.parse` (`lib/duckling.rb`) additionally spawns a real background `Thread` per call *when a `Fiber.scheduler` is installed on the calling thread*, which is what actually lets the calling Fiber yield via `Thread#value`'s scheduler hooks; a plain thread pool caller (Puma/Sidekiq-style, no Fiber scheduler) already gets its concurrency from `Native.parse`'s GVL release alone, so `Duckling.parse` skips the thread spawn entirely for those callers, and the spawned thread (when it does run) disables `report_on_exception` so a rescued error doesn't also print a thread-termination backtrace to stderr. See the wiki's `research-async-reactor-blocking` for the full research trail.
- **Known gotchas**:
  - `rb_sys` is a runtime gemspec dependency — needed even for precompiled binary gem consumers, since `rb_sys`'s Ruby-side code (not just the Rust crate) is loaded at runtime.
  - CI installs Rust via `dtolnay/rust-toolchain` and pins the version to track the Claude Code Web sandbox. Update `.github/workflows/main.yml`'s "Set up Rust" step when the sandbox image's Rust version changes.
  - Third-party GitHub actions are pinned to full commit SHAs with version comments (e.g. `actions/checkout@<sha> # vX.Y.Z`), not floating tags. `.github/dependabot.yml` opens PRs to bump these pins.
  - Cross-compiling locally (`rake 'native_gem[<platform>]'`) requires Docker.

## Gem release conventions

- **Versioning**: SemVer (`MAJOR.MINOR.PATCH`). Single source of truth: `Duckling::VERSION` in `lib/duckling/version.rb`.
- **Release process**: tag-triggered CI pipeline. Bump `Duckling::VERSION` in a PR, merge it to `main`, then push a matching `vX.Y.Z` git tag for that merged commit to trigger the pipeline.
- **Pipeline steps** (on tag push):
  1. CI gates (must be green before proceeding).
  2. Cross-compile `x86_64-linux` and `x86_64-darwin` binary gems via Docker containers.
  3. Build the `ruby` source gem.
  4. Push all three gems to RubyGems via `gem push`.
  5. Create a GitHub release with all three gems attached.
  6. Open and auto-merge a PR to update `CHANGELOG.md` (post-release documentation).
  7. In parallel with the release publish path after CI, record benchmark data for this release under `docs/benchmarks/github-actions/` and open/auto-merge that PR.
- **Tag protection**: `v*.*.*` tags can only be created/updated by repo admins. Configured via `.github/scripts/apply-tag-ruleset.sh`.
- **Before a release**: test cross-compilation locally or via `gh workflow run cross-gem.yml --ref <branch>`. Capture additional benchmark data points from other environments via `gh workflow run benchmark.yml --ref <branch>` (adds `docs/benchmarks/<environment>/` data) or locally via `bin/benchmark` (see "Build and test commands" above).

## `bin/` scripts (dev-workflow tooling, not part of the gem)

These come from the cpb Claude Code plugin's harness (commit `d69ba38`) and manage git worktrees / tmux / GitHub PR workflow for *this development environment* — they are not part of what ships in the gem and shouldn't be touched when working on the gem's actual functionality:

- `bin/worktree` — large CLI (`add`, `cd`, `harness`, `cleanup`, `heal-poll`, etc.) for creating per-issue git worktrees and driving Claude/Gemini sessions in tmux.
- `bin/check-worktree` — PreToolUse hook that blocks `Edit`/`Write` when on the `main` branch, steering you toward `bin/worktree add <branch>` instead.
- `bin/claude-code-web-setup` — PreToolUse hook for remote/web Claude Code sessions. Before each `Edit`/`Write`, just-in-time installs gems (`bundle install`) and compiles the native extension (`bundle exec rake compile`) — each step cached via receipt files in `tmp/claude-web-receipts/` so it's a no-op after the first call per session. Does not provision `hk`: `bin/lint` (see above) calls the underlying lint tools directly, so remote sessions never need `hk` installed — it's local-dev-only (see `hk.pkl`/`Brewfile` above). The gems/extension installers live in `bin/claude-web-deps.sh` (sourced, not directly executable); `bin/test` shares its `install_gems` installer (called unconditionally, any-args or no-args) since Bash tool calls don't trigger this Edit/Write-gated hook — `bin/test` no longer needs `compile_extension` itself, since `bundle exec rake test`'s `:compile` prerequisite handles that.

## Code comment conventions

Comments (in Ruby, Rust, and this file) are long-lived documentation, not a
transcript of the PR or session that wrote them. Prefer explaining the
durable *why* — the invariant, constraint, or measured behavior a future
reader needs — over narrating "issue #N added this" or "as of PR #M". If the
history genuinely matters (an empirical result, a design tradeoff explored
and rejected), link to its permanent home on the wiki rather than a bare
issue number, which reads as noise once the issue is closed and gives a
future reader nothing to follow.

## Keeping this file current

This file is manually maintained — there is no auto-generation. When you land
a PR that changes any of the following, **propose an update to AGENTS.md as
part of that PR** (don't leave it for someone else):

- Directory layout (new top-level dirs, moved files)
- Build/test commands (`bin/test`, `bin/lint`, `Rakefile` tasks)
- The Rust/Magnus wiring (`Cargo.toml`, `extconf.rb`, CI Rust toolchain setup, cross-compilation config) — keep the "Rust/Magnus wiring" section in sync with the actual, verified file contents
- The release process (`Rakefile` `release` task, `.github/workflows/release.yml`, `.github/workflows/cross-gem.yml`, `.github/workflows/benchmark.yml`) — keep "Gem release conventions" above in sync with the actual, verified workflow behavior
- Version numbers for tools/crates/gems — these belong in their own config files (`duckling.gemspec`, `ext/duckling/Cargo.toml`/`Cargo.lock`, `.standard.yml`, `hk.pkl`, CI workflow matrices), not here. If you need to reference a version, point to the file/field that holds it rather than copying the number, so this doc can't go stale when Dependabot or a manual bump changes it.

If you're an agent and notice this file is out of date with what you just
observed in the repo, fix it in the same PR rather than working around the
discrepancy silently.
