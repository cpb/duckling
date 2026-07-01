# AGENTS.md

Orientation for AI agents working in this repo. Read this before doing
exploratory reads — it should answer "where does X live" and "how do I build
the extension" without you having to re-derive them.

## What this is

`duckling` is a Ruby gem that wraps the Rust [`wafer-inc/duckling`](https://github.com/wafer-inc/duckling)
NER/entity-extraction engine via [Magnus](https://github.com/matsadler/magnus)
and `rb-sys`, so Ruby code can extract entities (times, numbers, money,
emails, etc.) without running a separate HTTP service.

**Current state: early bootstrap.** As of this writing the repo is close to
the stock `bundle gem duckling` skeleton — the Ruby API surface
(`lib/duckling.rb`), gemspec, and Rakefile exist, but the Rust extension
itself has not been implemented yet (`ext/duckling/extconf.rb` is an empty
placeholder) and the tag-triggered release pipeline has not been wired up.
Both are tracked as separate GitHub issues (#1 for the Rust extension, #4 for
the release pipeline) and may land as separate PRs. Sections below that
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
| `bin/` | Two kinds of scripts living side by side — see "bin/ scripts" below. Don't confuse the dev-workflow scripts (`worktree`, `check-worktree`, `claude-code-web-setup`, `lint`) with the gem's own build/test entrypoints (`setup`, `console`, `test`). |
| `duckling.gemspec` | Gem spec. Declares `spec.extensions = ["ext/duckling/extconf.rb"]` (the native-extension build entrypoint), depends on `rb_sys ~> 0.9.39`, dev-depends on `rake-compiler ~> 1.2.0`. Packaged files come from `git ls-files`, excluding `bin/`, `Gemfile`, `.gitignore`, `test/`, `.github/`, `.standard.yml`, `hk.pkl`. |
| `Rakefile` | `task default: %i[standard compile test]` — runs StandardRB lint, compiles the Rust extension, then Minitest. |
| `.standard.yml` | StandardRB config (`ruby_version: 3.3`). StandardRB wraps RuboCop internally; there is no separate `.rubocop.yml`. |
| `hk.pkl` | `hk` config (StandardRB + rustfmt + clippy via `hk`'s builtin steps) — single source of truth for local lint/format enforcement. `bin/lint` runs `hk fix` against it; not used by CI (CI runs the underlying tools directly, see below). |
| `.github/workflows/main.yml` | CI: on Ruby 3.3.6, sets up Rust (`dtolnay/rust-toolchain@stable` with `clippy`/`rustfmt` components), runs `cargo fmt --check` and `cargo clippy -- -D warnings` against `ext/duckling/`, then `bundle exec rake`. Runs for every push to `main` and every PR. |

## Build and test commands

- **`bin/setup`** — `bundle install`. Run this first in a fresh checkout/worktree.
- **`bin/console`** — loads the gem and drops you into IRB for interactive experimentation.
- **`bin/test [file:line]`** — runs `bundle exec ruby -I test "$@"`. With no args this needs a target file (it's a thin wrapper, not a full suite runner); for the full suite use `rake test` or `bundle exec rake`.
- **`bin/lint`** — the cpb-harness PostToolUse hook, invoked after every Edit/Write with `$CLAUDE_FILE_PATHS`. Runs `HK_PKL_BACKEND=pklr hk fix $CLAUDE_FILE_PATHS`, auto-correcting via `hk.pkl` (StandardRB for `.rb`, rustfmt for `.rs`). Requires `hk` on `PATH` (not installed via `bin/setup`/Gemfile — expected to be present on the dev machine, same as `cargo`/`rustc`).
- **`rake` / `bundle exec rake`** — default task: `standard` (StandardRB lint) + `compile` (builds the Rust extension via `Rake::ExtensionTask`) + `test` (Minitest).
- **Compiling the native extension**: `rake compile` (via `Rake::ExtensionTask`, wired in the `Rakefile`) builds `ext/duckling/` and places the compiled artifact under `lib/duckling/`.

## Rust/Magnus wiring

- **Rust crate location**: `ext/duckling/` (crate name `duckling_ext` in the planned design, to avoid clashing with the wrapped `duckling` crate).
- **The wrapped crate**: `wafer-inc/duckling`, published on crates.io as `duckling = "0.4"` (pure-Rust deps: regex, chrono, serde, serde_json, once_cell, smallvec — no bindgen/libclang required). Its main entrypoint is `duckling::parse(text, locale, dims, context, options) -> Vec<Entity>`; in release builds it wraps the parse in `catch_unwind` and returns `vec![]` on panic.
- **`extconf.rb` wiring (planned)**: `rb_sys/mkmf`'s `create_rust_makefile` ties Cargo into the Ruby `mkmf` build:
  ```ruby
  require "mkmf"
  require "rb_sys/mkmf"

  create_rust_makefile("duckling/duckling")
  ```
  The `"duckling/duckling"` argument controls the output path: the compiled artifact lands at `lib/duckling/duckling.bundle` (macOS) / `lib/duckling/duckling.so` (Linux), which is what `lib/duckling.rb` will `require_relative`.
- **`Cargo.toml` (planned)**: `cdylib` crate type, depends on `magnus` (`"0.8"`, with `features = ["chrono"]`), `duckling` (0.4, the wrapped crate), and `rb-sys` (`default-features = false, features = ["stable-api-compiled-fallback"]` — avoids needing libclang/bindgen on the build machine).
  - **Do not use `magnus = "0.9"`** — despite what some early design docs assumed, 0.9 has never been published to crates.io (only 0.8.2 is released as of this writing); pinning `"0.9"` will fail to resolve. The 0.8.2 API creates symbols via `ruby.to_symbol("key")`, not the 0.9-only `ruby.sym("key")`. Everything else (scan_args, get_kwargs, function!, RHash::aset, Ruby::ary_new, hash_new, chrono FixedOffset IntoValue) is unchanged between 0.8.2 and 0.9. Before trusting a magnus API claim from design docs, spot-check it against the actual published source (`~/.cargo/registry/src/index.crates.io-*/magnus-0.8.2/`).
- **Build model**: ships as a **source gem**, not precompiled binaries — installers need a Rust toolchain. `rake-compiler-dock` is already pulled in transitively (via `rb_sys` in `Gemfile.lock`) for possible future cross-compiled binary-gem support, but that's out of scope for now.
- **Known gotchas**:
  - `rb_sys` is already a runtime gemspec dependency (`~> 0.9.39`) even though the Rust crate doesn't exist yet — this is intentional, not a leftover.
  - CI installs a Rust toolchain via `dtolnay/rust-toolchain@stable` (with `clippy`/`rustfmt` components) and runs `cargo fmt --check` + `cargo clippy -- -D warnings` against `ext/duckling/` before `bundle exec rake`.
  - `.gitignore` does not yet exclude Rust build artifacts (`target/`, compiled `lib/duckling/*.bundle`/`*.so`) — add these when the crate is added.
  - Third-party actions in `.github/workflows/*.yml` are pinned to full commit SHAs (with the version as a trailing comment, e.g. `actions/checkout@<sha> # v6.0.3`), not floating tags — `.github/dependabot.yml`'s `github-actions` ecosystem entry opens PRs to bump these pins; don't hand-edit a `uses:` line back to a bare tag when copying it into new workflows.

## Gem release conventions

- **Versioning**: SemVer (`MAJOR.MINOR.PATCH`), single source of truth is `Duckling::VERSION` in `lib/duckling/version.rb`, consumed by `duckling.gemspec`.
- **Current state**: `CHANGELOG.md` (Keep a Changelog format) and the tag-triggered release pipeline (issue #4) are both live on `main`. The README's "release a new version" section still describes the stock `bundle exec rake release` flow (manual, via `bundler/gem_tasks`) — that's stale; don't run `rake release` manually.
- **Tag-triggered pipeline**: pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which:
  1. Re-runs the main CI workflow (`main.yml`) as a gate — release only proceeds if it's green.
  2. Verifies the pushed tag matches `Duckling::VERSION` exactly; fails the build on mismatch.
  3. `gem build` + `gem push` (via `RUBYGEMS_API_KEY` secret) and creates a GitHub release with `gh release create ... --generate-notes`.
  4. Appends a dated entry to `CHANGELOG.md` by committing to a `changelog/vX.Y.Z` branch, opening a PR (`gh pr create`), and auto-merging it (`gh pr merge --auto --squash`) — it does **not** push to `main` directly, since `main` requires PRs (see below).
  - **Release trigger going forward**: bump `Duckling::VERSION`, merge to `main`, then push a matching `vX.Y.Z` tag.
- **Branch protection on `main`** (issue #11): direct pushes are blocked — all changes, including the release pipeline's CHANGELOG commit, land via PR. Merging requires the `Ruby 3.3.6` status check to pass; branch deletion and force-pushes are disabled. No required review count (single-maintainer repo), so PRs merge as soon as CI is green.

## `bin/` scripts (dev-workflow tooling, not part of the gem)

These come from the cpb Claude Code plugin's harness (commit `d69ba38`) and manage git worktrees / tmux / GitHub PR workflow for *this development environment* — they are not part of what ships in the gem and shouldn't be touched when working on the gem's actual functionality:

- `bin/worktree` — large CLI (`add`, `cd`, `harness`, `cleanup`, `heal-poll`, etc.) for creating per-issue git worktrees and driving Claude/Gemini sessions in tmux.
- `bin/check-worktree` — PreToolUse hook that blocks `Edit`/`Write` when on the `main` branch, steering you toward `bin/worktree add <branch>` instead.
- `bin/claude-code-web-setup` — no-op skeleton hook for remote/web Claude Code sessions.

## Keeping this file current

This file is manually maintained — there is no auto-generation. When you land
a PR that changes any of the following, **propose an update to AGENTS.md as
part of that PR** (don't leave it for someone else):

- Directory layout (new top-level dirs, moved files)
- Build/test commands (`bin/test`, `bin/lint`, `Rakefile` tasks)
- The Rust/Magnus wiring (`Cargo.toml`, `extconf.rb`, CI Rust toolchain setup) — in particular, once issue #1's native extension lands, replace the **(planned)** Rust sections above with the actual, verified file contents
- The release process — once issue #4's tag-triggered pipeline lands, replace the **(planned)** release section above with the actual, verified workflow behavior

If you're an agent and notice this file is out of date with what you just
observed in the repo, fix it in the same PR rather than working around the
discrepancy silently.
