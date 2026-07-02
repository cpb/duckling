# AGENTS.md

Orientation for AI agents working in this repo. Read this before doing
exploratory reads — it should answer "where does X live" and "how do I build
the extension" without you having to re-derive them.

## What this is

`duckling` is a Ruby gem that wraps the Rust [`wafer-inc/duckling`](https://github.com/wafer-inc/duckling)
NER/entity-extraction engine via [Magnus](https://github.com/matsadler/magnus)
and `rb-sys`, so Ruby code can extract entities (times, numbers, money,
emails, etc.) without running a separate HTTP service.

**Current state:** the native Rust extension, Ruby API surface, gemspec, and
Rakefile all exist and are live, as is the tag-triggered release pipeline
(issue #4) — see "Gem release conventions" below. As of 0.3.0 (issue #32),
`Duckling.parse` returns immutable `Data` value objects (`Duckling::Entity`,
`Duckling::TimeValue::{Single,Interval}`, `Duckling::TimePoint::{Naive,Instant}`),
not `Hash`es — see "Rust/Magnus wiring" below for how that's built.

## Directory layout

| Path | Purpose |
|---|---|
| `ext/duckling/` | Native Rust extension. Holds `extconf.rb` (build wiring), `Cargo.toml`, and `src/lib.rs` + `src/ruby_value.rs`. See "Rust/Magnus wiring" below. |
| `lib/duckling.rb` | Defines the public `Duckling.parse` method (pure Ruby) — calls `Duckling::Native.parse` (the compiled extension, required via `require_relative "duckling/duckling"`) and converts its raw output into `Data` objects via `Duckling::Entities.build` (`lib/duckling/entities.rb`). No `Duckling::Error` class — invalid `locale:`/`dims:` raise plain `ArgumentError`. |
| `lib/duckling/entities.rb` | `Duckling::Entity`/`Duckling::TimeValue::{Single,Interval}`/`Duckling::TimePoint::{Naive,Instant}` `Data` classes, plus `Duckling::Entities.build` — the `case/in` factory that pattern-matches `Duckling::Native.parse`'s raw symbol-keyed, externally-tagged `Hash` into them. See `docs/issue-32-serde-magnus-comparison.md` for why this shape was chosen over returning `Hash`es directly. |
| `lib/duckling/version.rb` | `Duckling::VERSION` constant — single source of truth for the gem version, read by `duckling.gemspec` and (once built) the release pipeline. |
| `test/` | Minitest suite. `test_helper.rb` sets up the load path and requires `minitest/autorun`; test files currently follow `test_<name>.rb` / `class Test<Name> < Minitest::Test` naming. |
| `bin/` | Two kinds of scripts living side by side — see "bin/ scripts" below. Don't confuse the dev-workflow scripts (`worktree`, `check-worktree`, `claude-code-web-setup`, `lint`) with the gem's own build/test/benchmark entrypoints (`setup`, `console`, `test`, `benchmark_parse`). |
| `Brewfile` | Homebrew deps for building the native extension locally on macOS (currently just `rust`, which bundles `cargo`/`rustc`/`rustfmt`/`clippy` together). `bin/setup` runs `brew bundle` against it when Homebrew is present. |
| `duckling.gemspec` | Gem spec. Declares `spec.extensions = ["ext/duckling/extconf.rb"]` (the native-extension build entrypoint), depends on `rb_sys` and dev-depends on `rake-compiler` — see the gemspec's `add_dependency`/`add_development_dependency` lines for the current version constraints. Packaged files come from `git ls-files`, excluding `bin/`, `Gemfile`, `.gitignore`, `.env.local.example`, `test/`, `.github/`, `.standard.yml`, `hk.pkl`. |
| `Rakefile` | `task default: %i[standard compile test]` — runs StandardRB lint, compiles the Rust extension, then Minitest. Loads `.env.local` via `Dotenv.load` at the top (no-ops if absent, e.g. in CI); also defines an opt-in `:dev` task (not part of `default`) that sets `RB_SYS_CARGO_PROFILE=dev` directly — use `bundle exec rake dev compile test` for a one-off dev-profile build without `.env.local` in place. See "Build and test commands" below for how the two relate. |
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
- **`bin/benchmark_parse`** — not part of `rake test`; run directly to compare `Duckling.parse`'s speed and per-call object-allocation count (`GC.stat[:total_allocated_objects]` diffing + `benchmark-ips`) across representative inputs. Added for issue #32's Option B vs. Option D comparison (see `docs/issue-32-serde-magnus-comparison.md`); re-run it before/after future conversion-layer changes rather than guessing at allocation cost.

## Rust/Magnus wiring

- **Rust crate location**: `ext/duckling/`, crate name `duckling` (Cargo package name, not to be confused with the wrapped `duckling` crate — they coexist as separate entries in `Cargo.lock` since one's a path dependency and the other's a crates.io dependency).
- **The wrapped crate**: `wafer-inc/duckling`, published on crates.io as `duckling` (pure-Rust deps: regex, chrono, serde, serde_json, once_cell, smallvec — no bindgen/libclang required); see `ext/duckling/Cargo.toml` for the pinned version constraint (`"0.4"`, resolves to 0.4.0). Its main entrypoint is `duckling::parse(text, locale, dims, context, options) -> Vec<Entity>`; in release builds it wraps the parse in `catch_unwind` and returns `vec![]` on panic. `Entity`/`DimensionValue`/`TimeValue`/`TimePoint`/`Grain` all derive plain `serde::Serialize` with no container-level `tag`/`rename_all` attributes (only two field-level `skip_serializing_if`s, on `Entity.latent` and `TimeValue`'s `holiday`) — this is what `serde_magnus::serialize` (below) walks.
- **`extconf.rb` wiring**: `rb_sys/mkmf`'s `create_rust_makefile` ties Cargo into the Ruby `mkmf` build:
  ```ruby
  require "mkmf"
  require "rb_sys/mkmf"

  create_rust_makefile("duckling/duckling")
  ```
  The `"duckling/duckling"` argument controls the output path: the compiled artifact lands at `lib/duckling/duckling.bundle` (macOS) / `lib/duckling/duckling.so` (Linux), which `lib/duckling.rb` loads via `require_relative "duckling/duckling"`.
- **`Cargo.toml`**: `cdylib` crate type, depends on `magnus = "0.8"` (resolves to 0.8.2), `duckling = "0.4"` (the wrapped crate), `chrono = "0.4"`, `serde = "1"`, `serde_magnus = "0.11"`, and `rb-sys` (`default-features = false, features = ["stable-api-compiled-fallback"]` — avoids needing libclang/bindgen on the build machine).
  - **Do not use `magnus = "0.9"`** — 0.9 has never been published to crates.io (only 0.8.2 is released as of this writing); pinning `"0.9"` will fail to resolve. The 0.8.2 API creates symbols via `ruby.to_symbol("key")`, not the 0.9-only `ruby.sym("key")`. Before trusting a magnus API claim from design docs, spot-check it against the actual published source (`~/.cargo/registry/src/index.crates.io-*/magnus-0.8.2/`).
- **`src/lib.rs`**: defines `Duckling::Native.parse(text, locale:, dims:, reference_time:, with_latent:)` (registered under a nested `Native` module, not directly on `Duckling`, since `Duckling.parse` itself is now a pure-Ruby method — see `lib/duckling.rb` above). Converts each `Entity` via `serde_magnus::serialize` + `ruby_value::symbolize_keys_in_place`, returning a symbol-keyed, externally-tagged `Hash` (e.g. `{value: {Time: {Single: {value: {Naive: {value: "...", grain: "Day"}}, values: [...]}}}}`) — *not* the polished `Data`-object shape callers see from `Duckling.parse`; that conversion happens entirely in Ruby (`lib/duckling/entities.rb`). Arg-parsing helpers (`parse_locale`, `parse_dims`, `build_context`) are unchanged from earlier versions.
- **`src/ruby_value.rs`**: `symbolize_keys_in_place` — recursively rewrites `Hash` keys from `String` to `Symbol` **in place** (via `Hash#delete`/`Hash#aset` on the same `RHash`, not by rebuilding a new `Hash`/`Array` tree) to avoid doubling `serde_magnus`'s already-heavier (externally-tagged) allocation footprint. **GC-safety rule learned the hard way here** (see `docs/issue-32-serde-magnus-comparison.md` for the full incident): never stash a `magnus::Value` pulled off a `Hash`/`Array` into a Rust-native `Vec`/`Box`/struct field across any further Magnus call — once it's off the Ruby-visible object graph, MRI's conservative stack-scanning GC can't see it anymore and a subsequent GC cycle can free it out from under you (this caused a real, reproducible segfault under load, fixed by staging keys in a Ruby `RArray` instead of a Rust `Vec`). `Value`s are safe to hold across Magnus calls only in plain Rust stack-local variables (function params/locals), never in heap containers.
- **Build model**: ships as a **source gem**, not precompiled binaries — installers need a Rust toolchain. `rake-compiler-dock` is already pulled in transitively (via `rb_sys` in `Gemfile.lock`) for possible future cross-compiled binary-gem support, but that's out of scope for now.
- **Known gotchas**:
  - CI installs a Rust toolchain via `dtolnay/rust-toolchain` (with `clippy`/`rustfmt` components), pinned via the `toolchain:` input to a specific version tracking the Rust pre-installed in the Claude Code Web sandbox image — see `.github/workflows/main.yml`'s "Set up Rust" step for the exact pinned version. Bump it there (with the SHA comment updated) when the sandbox image's Rust version changes; don't let it float on `stable`, since that can drift out of sync with what an agent can run in the sandbox without an extra install. Then CI runs `cargo fmt --check` + `cargo clippy -- -D warnings` against `ext/duckling/` before `bundle exec rake`.
  - A raw `cargo build`/`cargo build --release` run directly inside `ext/duckling/` will fail to link (`symbol(s) not found for architecture ...`, missing `_rb_*` symbols) — it skips the `-C link-arg=-Wl,-undefined,dynamic_lookup` and Ruby library search paths that `rb_sys`/`rake-compiler` inject. Always build via `bundle exec rake compile` (or `bundle exec rake dev compile`) from the gem root, never a bare `cargo build`, when checking whether Rust changes actually compile against Ruby.
  - Third-party actions in `.github/workflows/*.yml` are pinned to full commit SHAs (with the version as a trailing comment, e.g. `actions/checkout@<sha> # vX.Y.Z`), not floating tags — see the workflow files themselves for what's currently pinned. `.github/dependabot.yml`'s `github-actions` ecosystem entry opens PRs to bump these pins; don't hand-edit a `uses:` line back to a bare tag when copying it into new workflows.

## Gem release conventions

- **Versioning**: SemVer (`MAJOR.MINOR.PATCH`), single source of truth is `Duckling::VERSION` in `lib/duckling/version.rb`, consumed by `duckling.gemspec`.
- **Current state**: `CHANGELOG.md` (Keep a Changelog format) and the tag-triggered release pipeline (issue #4) are both live on `main`. `rake release` no longer runs the stock `bundler/gem_tasks` flow — the `Rakefile` narrows it to just creating and pushing the `vX.Y.Z` git tag (see `release:guard_clean`/`release:source_control_push`), since building and pushing the `.gem` is now CI's job (issue #24). The README's "release a new version" section documents this flow.
- **Tag-triggered pipeline**: pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which:
  1. Re-runs the main CI workflow (`main.yml`) as a gate — release only proceeds if it's green.
  2. Verifies the pushed tag matches `Duckling::VERSION` exactly; fails the build on mismatch.
  3. `gem build` + `gem push` (via `RUBYGEMS_API_KEY` secret) and creates a GitHub release with `gh release create ... --generate-notes`.
  4. Appends a dated entry to `CHANGELOG.md` by committing to a `changelog/vX.Y.Z` branch, opening a PR (`gh pr create`), and auto-merging it (`gh pr merge --auto --squash`) — it does **not** push to `main` directly, since `main` requires PRs (see below).
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
- The Rust/Magnus wiring (`Cargo.toml`, `extconf.rb`, `src/*.rs`, CI Rust toolchain setup) — keep "Rust/Magnus wiring" above in sync with the actual, verified file contents
- The release process (`Rakefile` `release` task, `.github/workflows/release.yml`) — keep "Gem release conventions" above in sync with the actual, verified workflow behavior
- Version numbers for tools/crates/gems — these belong in their own config files (`duckling.gemspec`, `ext/duckling/Cargo.toml`/`Cargo.lock`, `.standard.yml`, `hk.pkl`, CI workflow matrices), not here. If you need to reference a version, point to the file/field that holds it rather than copying the number, so this doc can't go stale when Dependabot or a manual bump changes it.

If you're an agent and notice this file is out of date with what you just
observed in the repo, fix it in the same PR rather than working around the
discrepancy silently.
