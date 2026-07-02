# AGENTS.md

Orientation for AI agents working in this repo. Read this before doing
exploratory reads — it should answer "where does X live" and "how do I build
the extension" without you having to re-derive them.

## What this is

`duckling` is a Ruby gem that wraps the Rust [`wafer-inc/duckling`](https://github.com/wafer-inc/duckling)
NER/entity-extraction engine via [Magnus](https://github.com/matsadler/magnus)
and `rb-sys`, so Ruby code can extract entities (times, numbers, money,
emails, etc.) without running a separate HTTP service.

**Current state:** the Ruby API surface (`lib/duckling.rb`), gemspec, and
Rakefile exist, and the tag-triggered release pipeline (issue #4) has landed
and is live — see "Gem release conventions" below. Sections below that
describe not-yet-built pieces are marked **(planned)** — verify against the
actual files before relying on exact contents, and update this file once the
real implementation lands (see "Keeping this file current").

## Directory layout

| Path | Purpose |
|---|---|
| `ext/duckling/` | Native Rust extension. Holds `extconf.rb` (build wiring) and, once implemented, `Cargo.toml` + `src/`. See "Rust/Magnus wiring" below. |
| `lib/duckling.rb` | Ruby module entrypoint (`Duckling` module, `Duckling::Error`). Will `require_relative "duckling/duckling"` to load the compiled native extension once it exists. |
| `lib/duckling/version.rb` | `Duckling::VERSION` constant — single source of truth for the gem version, read by `duckling.gemspec` and (once built) the release pipeline. |
| `test/` | Minitest suite. `test_helper.rb` sets up the load path and requires `minitest/autorun`; test files currently follow `test_<name>.rb` / `class Test<Name> < Minitest::Test` naming. |
| `bin/` | Two kinds of scripts living side by side — see "bin/ scripts" below. Don't confuse the dev-workflow scripts (`worktree`, `check-worktree`, `claude-code-web-setup`, `lint`) with the gem's own build/test entrypoints (`setup`, `console`, `test`, `benchmark`). |
| `benchmark/` | `benchmark-ips`-based suite exercising `Duckling.parse` (`parse_benchmark.rb`: ips + GC/allocation pressure + threaded-concurrency scenarios) and the environment-aware recording/reporting logic (`report.rb`: writes `docs/benchmarks/<environment>/<version>.json`, regenerates `docs/benchmarks/README.md`). Not part of what ships in the gem (excluded from packaging in `duckling.gemspec`) or of `task default:` (too slow/non-deterministic for every `bundle exec rake`). Run via `bin/benchmark` — see "Build and test commands" below. |
| `docs/benchmarks/` | Per-environment, per-version benchmark history: `<environment>/<version>.json` raw results plus an auto-generated `README.md` (owned entirely by `DucklingBenchmark::Report.write_docs_readme!` — never hand-edited) with Mermaid charts comparing environments. Committed to git but excluded from the packaged gem. Linked from the root `README.md`'s "Performance" section. |
| `Brewfile` | Homebrew deps for building the native extension and recording benchmarks locally on macOS: `rust` (bundles `cargo`/`rustc`/`rustfmt`/`clippy`) and `gh` (GitHub CLI, used by `benchmark:record_pr` to open PRs). `bin/setup` runs `brew bundle` against it when Homebrew is present. `gh` still needs `gh auth login` before `benchmark:record_pr` can push/open a PR. |
| `duckling.gemspec` | Gem spec. Declares `spec.extensions = ["ext/duckling/extconf.rb"]` (the native-extension build entrypoint), depends on `rb_sys` and dev-depends on `rake-compiler` + `benchmark-ips` — see the gemspec's `add_dependency`/`add_development_dependency` lines for the current version constraints. Packaged files come from `git ls-files`, excluding `bin/`, `Gemfile`, `.gitignore`, `.env.local.example`, `test/`, `.github/`, `.standard.yml`, `hk.pkl`, `benchmark/`, `docs/benchmarks/`. |
| `Rakefile` | `task default: %i[standard compile test]` — runs StandardRB lint, compiles the Rust extension, then Minitest. Loads `.env.local` via `Dotenv.load` at the top (no-ops if absent, e.g. in CI); also defines an opt-in `:dev` task (not part of `default`) that sets `RB_SYS_CARGO_PROFILE=dev` directly — use `bundle exec rake dev compile test` for a one-off dev-profile build without `.env.local` in place. Also defines `benchmark` / `benchmark:record` / `benchmark:record_pr` (all deliberately excluded from `task default:`) — see "Build and test commands" below for how they relate. |
| `.env.local.example` | Tracked template for `.env.local` (gitignored) — sets `RB_SYS_CARGO_PROFILE=dev` so `bin/setup` (see below) makes the dev Cargo profile the local default. |
| `.standard.yml` | StandardRB config — see its `ruby_version:` field for the Ruby version StandardRB targets. StandardRB wraps RuboCop internally; there is no separate `.rubocop.yml`. |
| `hk.pkl` | `hk` config (StandardRB + rustfmt + clippy via `hk`'s builtin steps), kept for anyone running `hk` manually/in CI environments with GitHub access. `bin/lint` no longer shells out to it (see below) — it runs the same underlying tools directly, since `hk`'s Pkl config needs to fetch its schema package from a GitHub release on every invocation. Not used by CI either (CI runs the underlying tools directly, see below). |
| `.github/workflows/main.yml` | CI: on the Ruby version(s) in the `ruby:` matrix, sets up Rust via `dtolnay/rust-toolchain` pinned to a specific version (with `clippy`/`rustfmt` components) tracking the Claude Code Web sandbox's pre-installed Rust — see the "Set up Rust" step's `toolchain:` input for the exact version — then runs `cargo fmt --check` and `cargo clippy -- -D warnings` against `ext/duckling/`, then `bundle exec rake`. Runs for every push to `main` and every PR. |
| `.github/workflows/release.yml` | Tag-triggered release: builds and pushes the gem to RubyGems and cuts a GitHub release. See "Gem release conventions" below. |
| `.github/scripts/apply-tag-ruleset.sh` | Idempotent `gh api` script that creates/updates the GitHub tag ruleset restricting `v*.*.*` tag creation/update to repo admins. Source of truth for that ruleset's config — re-run it to change the config rather than editing it by hand in the GitHub UI. |

## Build and test commands

- **`bin/setup`** — runs `brew bundle` (installing the Rust toolchain per `Brewfile`) when Homebrew is present, then `bundle install`, then (if `.env.local` doesn't already exist) copies `.env.local.example` to `.env.local`, which sets `RB_SYS_CARGO_PROFILE=dev`. No-ops the Homebrew step gracefully on machines without `brew` (e.g. CI runners, which install Rust separately — see below). Run this first in a fresh checkout/worktree.
- **`bin/console`** — loads the gem and drops you into IRB for interactive experimentation.
- **`bin/test [file:line]`** — with an argument, runs `bundle exec ruby -I test "$@"` against that target; with no arguments, runs the full suite via `bundle exec rake` instead (equivalent to `rake test`/`bundle exec rake`). In a remote Claude Code Web session (`CLAUDE_CODE_REMOTE=true`), either path first JIT-installs gems and compiles the extension via `bin/claude-web-deps.sh` (unconditionally, not just the no-arg case — the `file:line` path needs the compiled extension too and bypasses rake, so it can't rely on `rake compile` to provide it), since a bare Bash call doesn't trigger the Edit/Write-gated `bin/claude-code-web-setup` PreToolUse hook.
- **`bin/lint`** — the cpb-harness PostToolUse hook, invoked after every Edit/Write with `$CLAUDE_FILE_PATHS`. Splits the changed paths by extension and auto-fixes them directly with the same tools CI runs (`bundle exec standardrb --fix` for `.rb` files, `rustfmt` + `cargo clippy --fix` against `ext/duckling/Cargo.toml` for `.rs` files) — it does not shell out to `hk`, since `hk`'s Pkl-based config (`hk.pkl`) requires fetching its schema package from a GitHub release on every invocation, which isn't reliable in sandboxed/network-restricted dev environments. Requires `standardrb` (via `bundle install`) and `rustfmt`/`cargo clippy` (rustup components) on `PATH`.
- **`rake` / `bundle exec rake`** — default task: `standard` (StandardRB lint) + `compile` (builds the Rust extension via `Rake::ExtensionTask`) + `test` (Minitest).
- **Compiling the native extension**: `rake compile` (via `Rake::ExtensionTask`, wired in the `Rakefile`) builds `ext/duckling/` and places the compiled artifact under `lib/duckling/`. After `bin/setup` has run, this builds Cargo's `dev` profile locally (faster compile, slower runtime) because `.env.local` sets `RB_SYS_CARGO_PROFILE=dev` and the Rakefile loads it via `Dotenv.load(".env.local")`. `.env.local` is gitignored and never present in CI, so `bundle exec rake` in CI (`main.yml`) and `rake release` always build the optimized `release` profile regardless of this.
- **`rake dev compile test`** — explicit one-off dev-profile build via the `:dev` task, for use without `.env.local` in place (e.g. before running `bin/setup`, or in an environment where you don't want it seeded).
- **`bin/benchmark`** — thin wrapper around the `benchmark`/`benchmark:record`/`benchmark:record_pr` Rake tasks (below), matching `bin/test`'s `CLAUDE_CODE_REMOTE` JIT-setup convention.
- **`rake benchmark`** — runs the `benchmark-ips` suite in `benchmark/parse_benchmark.rb` (ips + GC/allocation pressure + 10-thread concurrency scenarios) against a forced release-profile build (via the `:benchmark_env` task, which unsets `RB_SYS_CARGO_PROFILE` and reenables `:compile` regardless of a local `.env.local`); console output only, no files written. Not part of `task default:` — too slow (~25-30s) for every `bundle exec rake`.
- **`rake "benchmark:record"`** — runs `benchmark`, then writes `docs/benchmarks/<environment>/<version>.json` (environment auto-detected: `github-actions` if `GITHUB_ACTIONS=true`, `claude-code-web` if `CLAUDE_CODE_REMOTE=true`, else `local`; version from `Duckling::VERSION`) and regenerates `docs/benchmarks/README.md` from the full history.
- **`rake "benchmark:record_pr"`** — guarded by the existing `release:guard_clean` task (refuses to run against a dirty working tree); checks out a fresh branch off `origin/main`, runs `benchmark:record` there, commits, pushes, and opens+auto-merges a PR via `gh` — then restores the original branch. Meant to be run from three places: the tag-triggered release pipeline (`.github/workflows/release.yml`), a Claude Code Web session, and a local dev machine (needs `gh auth login`) — each contributes that environment's own data point via its own PR, independent of the CHANGELOG PR.

## Rust/Magnus wiring

- **Rust crate location**: `ext/duckling/` (crate name `duckling_ext` in the planned design, to avoid clashing with the wrapped `duckling` crate).
- **The wrapped crate**: `wafer-inc/duckling`, published on crates.io as `duckling` (pure-Rust deps: regex, chrono, serde, serde_json, once_cell, smallvec — no bindgen/libclang required); see `ext/duckling/Cargo.toml` for the pinned version constraint. Its main entrypoint is `duckling::parse(text, locale, dims, context, options) -> Vec<Entity>`; in release builds it wraps the parse in `catch_unwind` and returns `vec![]` on panic.
- **`extconf.rb` wiring (planned)**: `rb_sys/mkmf`'s `create_rust_makefile` ties Cargo into the Ruby `mkmf` build:
  ```ruby
  require "mkmf"
  require "rb_sys/mkmf"

  create_rust_makefile("duckling/duckling")
  ```
  The `"duckling/duckling"` argument controls the output path: the compiled artifact lands at `lib/duckling/duckling.bundle` (macOS) / `lib/duckling/duckling.so` (Linux), which is what `lib/duckling.rb` will `require_relative`.
- **`Cargo.toml` (planned)**: `cdylib` crate type, depends on `magnus` (with `features = ["chrono"]`), `duckling` (the wrapped crate), and `rb-sys` (`default-features = false, features = ["stable-api-compiled-fallback"]` — avoids needing libclang/bindgen on the build machine); see `ext/duckling/Cargo.toml` for exact version constraints.
  - **Do not use `magnus = "0.9"`** — despite what some early design docs assumed, 0.9 has never been published to crates.io (only 0.8.2 is released as of this writing); pinning `"0.9"` will fail to resolve. The 0.8.2 API creates symbols via `ruby.to_symbol("key")`, not the 0.9-only `ruby.sym("key")`. Everything else (scan_args, get_kwargs, function!, RHash::aset, Ruby::ary_new, hash_new, chrono FixedOffset IntoValue) is unchanged between 0.8.2 and 0.9. Before trusting a magnus API claim from design docs, spot-check it against the actual published source (`~/.cargo/registry/src/index.crates.io-*/magnus-0.8.2/`).
- **Build model**: ships as a **source gem**, not precompiled binaries — installers need a Rust toolchain. `rake-compiler-dock` is already pulled in transitively (via `rb_sys` in `Gemfile.lock`) for possible future cross-compiled binary-gem support, but that's out of scope for now.
- **Known gotchas**:
  - `rb_sys` is already a runtime gemspec dependency (see `duckling.gemspec` for the version constraint) even though the Rust crate doesn't exist yet — this is intentional, not a leftover.
  - CI installs a Rust toolchain via `dtolnay/rust-toolchain` (with `clippy`/`rustfmt` components), pinned via the `toolchain:` input to a specific version tracking the Rust pre-installed in the Claude Code Web sandbox image — see `.github/workflows/main.yml`'s "Set up Rust" step for the exact pinned version. Bump it there (with the SHA comment updated) when the sandbox image's Rust version changes; don't let it float on `stable`, since that can drift out of sync with what an agent can run in the sandbox without an extra install. Then CI runs `cargo fmt --check` + `cargo clippy -- -D warnings` against `ext/duckling/` before `bundle exec rake`.
  - `.gitignore` does not yet exclude Rust build artifacts (`target/`, compiled `lib/duckling/*.bundle`/`*.so`) — add these when the crate is added.
  - Third-party actions in `.github/workflows/*.yml` are pinned to full commit SHAs (with the version as a trailing comment, e.g. `actions/checkout@<sha> # vX.Y.Z`), not floating tags — see the workflow files themselves for what's currently pinned. `.github/dependabot.yml`'s `github-actions` ecosystem entry opens PRs to bump these pins; don't hand-edit a `uses:` line back to a bare tag when copying it into new workflows.

## Gem release conventions

- **Versioning**: SemVer (`MAJOR.MINOR.PATCH`), single source of truth is `Duckling::VERSION` in `lib/duckling/version.rb`, consumed by `duckling.gemspec`.
- **Current state**: `CHANGELOG.md` (Keep a Changelog format) and the tag-triggered release pipeline (issue #4) are both live on `main`. `rake release` no longer runs the stock `bundler/gem_tasks` flow — the `Rakefile` narrows it to just creating and pushing the `vX.Y.Z` git tag (see `release:guard_clean`/`release:source_control_push`), since building and pushing the `.gem` is now CI's job (issue #24). The README's "release a new version" section documents this flow.
- **Tag-triggered pipeline**: pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which:
  1. Re-runs the main CI workflow (`main.yml`) as a gate — release only proceeds if it's green.
  2. Verifies the pushed tag matches `Duckling::VERSION` exactly; fails the build on mismatch.
  3. `gem build` + `gem push` (via `RUBYGEMS_API_KEY` secret) and creates a GitHub release with `gh release create ... --generate-notes`.
  4. Appends a dated entry to `CHANGELOG.md` by committing to a `changelog/vX.Y.Z` branch, opening a PR (`gh pr create`), and auto-merging it (`gh pr merge --auto --squash`) — it does **not** push to `main` directly, since `main` requires PRs (see below).
  5. Runs `bundle exec rake benchmark:record_pr` (issue #36) — an independent step/PR from the CHANGELOG one above, recording that CI run's benchmark numbers under `docs/benchmarks/github-actions/<version>.json` and regenerating `docs/benchmarks/README.md`, then opening+auto-merging its own PR. The same task is also meant to be run ad hoc from a Claude Code Web session or a local dev machine prior to a release, to build up the other environments' data points (`docs/benchmarks/README.md`'s charts compare environments against each other, not a single blended release-over-release trend — see `benchmark/report.rb`). `CHANGELOG.md` itself is not touched by any of this.
  - **Release trigger going forward**: bump `Duckling::VERSION`, merge to `main`, then push a matching `vX.Y.Z` tag.
- **Branch protection on `main`** (issue #11): direct pushes are blocked — all changes, including the release pipeline's CHANGELOG commit, land via PR. Merging requires the CI status check to pass — named `Ruby <version>`, where `<version>` comes from the `ruby:` matrix in `main.yml`; branch deletion and force-pushes are disabled. No required review count (single-maintainer repo), so PRs merge as soon as CI is green.
- **Tag ruleset** (issue #12): a GitHub tag ruleset named "Protect release tags" restricts creation/update of `v*.*.*` tags to repo admins, so only authorized pushers can trigger the pipeline above. Configured via `.github/scripts/apply-tag-ruleset.sh` (`gh api repos/{owner}/{repo}/rulesets`) — re-run that script to change the ruleset rather than editing it by hand in the GitHub UI, so the config stays reviewable in version control. Signing tags is out of scope (deferred).

## `bin/` scripts (dev-workflow tooling, not part of the gem)

These come from the cpb Claude Code plugin's harness (commit `d69ba38`) and manage git worktrees / tmux / GitHub PR workflow for *this development environment* — they are not part of what ships in the gem and shouldn't be touched when working on the gem's actual functionality:

- `bin/worktree` — large CLI (`add`, `cd`, `harness`, `cleanup`, `heal-poll`, etc.) for creating per-issue git worktrees and driving Claude/Gemini sessions in tmux.
- `bin/check-worktree` — PreToolUse hook that blocks `Edit`/`Write` when on the `main` branch, steering you toward `bin/worktree add <branch>` instead.
- `bin/claude-code-web-setup` — PreToolUse hook for remote/web Claude Code sessions. Before each `Edit`/`Write`, just-in-time installs gems (`bundle install`), compiles the native extension (`bundle exec rake compile`), and provisions `hk` (installing the binary and running `hk install` if missing, best-effort — a failure here warns but doesn't block the edit) — each step cached via receipt files in `tmp/claude-web-receipts/` so it's a no-op after the first call per session. The gems/extension installers live in `bin/claude-web-deps.sh` (sourced, not directly executable), shared with `bin/test`'s no-arg path since Bash tool calls don't trigger this Edit/Write-gated hook.

## Keeping this file current

This file is manually maintained — there is no auto-generation. When you land
a PR that changes any of the following, **propose an update to AGENTS.md as
part of that PR** (don't leave it for someone else):

- Directory layout (new top-level dirs, moved files)
- Build/test commands (`bin/test`, `bin/lint`, `Rakefile` tasks)
- The Rust/Magnus wiring (`Cargo.toml`, `extconf.rb`, CI Rust toolchain setup) — in particular, once issue #1's native extension lands, replace the **(planned)** Rust sections above with the actual, verified file contents
- The release process (`Rakefile` `release` task, `.github/workflows/release.yml`) — keep "Gem release conventions" above in sync with the actual, verified workflow behavior
- Version numbers for tools/crates/gems — these belong in their own config files (`duckling.gemspec`, `ext/duckling/Cargo.toml`/`Cargo.lock`, `.standard.yml`, `hk.pkl`, CI workflow matrices), not here. If you need to reference a version, point to the file/field that holds it rather than copying the number, so this doc can't go stale when Dependabot or a manual bump changes it.

If you're an agent and notice this file is out of date with what you just
observed in the repo, fix it in the same PR rather than working around the
discrepancy silently.
