# AGENTS.md

Orientation for AI agents working in this repo. Read this before doing
exploratory reads — it should answer "where does X live" and "how do I build
the extension" without you having to re-derive them.

## What this is

`duckling` is a Ruby gem that wraps the Rust [`wafer-inc/duckling`](https://github.com/wafer-inc/duckling)
NER/entity-extraction engine via [Magnus](https://github.com/matsadler/magnus)
and `rb-sys`, so Ruby code can extract entities (times, numbers, money,
emails, etc.) without running a separate HTTP service.

**Current state:** the Ruby API surface (`lib/duckling.rb`), gemspec,
Rakefile, and native extension (issue #1) are all built and live, the
tag-triggered release pipeline (issue #4) has landed, and precompiled binary
gems for `x86_64-linux`/`x86_64-darwin` (issue #43) are now published
alongside the source gem — see "Build model" under "Rust/Magnus wiring" and
"Gem release conventions" below. If you notice this file describing a
not-yet-built piece as current, or vice versa, fix it in the same PR (see
"Keeping this file current").

## Directory layout

| Path | Purpose |
|---|---|
| `ext/duckling/` | Native Rust extension. Holds `extconf.rb` (build wiring) and, once implemented, `Cargo.toml` + `src/`. See "Rust/Magnus wiring" below. |
| `lib/duckling.rb` | Ruby module entrypoint (`Duckling` module, `Duckling::Error`). Will `require_relative "duckling/duckling"` to load the compiled native extension once it exists. |
| `lib/duckling/version.rb` | `Duckling::VERSION` constant — single source of truth for the gem version, read by `duckling.gemspec` and (once built) the release pipeline. |
| `test/` | Minitest suite. `test_helper.rb` sets up the load path and requires `minitest/autorun`; test files currently follow `test_<name>.rb` / `class Test<Name> < Minitest::Test` naming. |
| `bin/` | Two kinds of scripts living side by side — see "bin/ scripts" below. Don't confuse the dev-workflow scripts (`worktree`, `check-worktree`, `claude-code-web-setup`, `lint`) with the gem's own build/test entrypoints (`setup`, `console`, `test`). |
| `Brewfile` | Homebrew deps for local macOS dev: `rust` (bundles `cargo`/`rustc`/`rustfmt`/`clippy`) and `hk` (see `hk.pkl` below — local-dev-only, not installed in CI or remote/web sessions). `bin/setup` runs `brew bundle` against it, then `hk install`, when Homebrew is present. |
| `duckling.gemspec` | Gem spec. Declares `spec.extensions = ["ext/duckling/extconf.rb"]` (the native-extension build entrypoint), depends on `rb_sys` and dev-depends on `rake-compiler` — see the gemspec's `add_dependency`/`add_development_dependency` lines for the current version constraints. Packaged files come from `git ls-files`, excluding `bin/`, `Gemfile`, `.gitignore`, `.env.local.example`, `test/`, `.github/`, `.standard.yml`, `hk.pkl`. |
| `Rakefile` | `task default: %i[standard compile test]` — runs StandardRB lint, compiles the Rust extension, then Minitest. `test` also declares an explicit `task test: :compile` prerequisite (`Minitest::TestTask` has no built-in way to express this itself), so `bundle exec rake test` run in isolation still compiles first — not just `bundle exec rake` via the `default` array's ordering. Loads `.env.local` via `Dotenv.load` at the top (no-ops if absent, e.g. in CI); also defines an opt-in `:dev` task (not part of `default`) that sets `RB_SYS_CARGO_PROFILE=dev` directly — use `bundle exec rake dev compile test` for a one-off dev-profile build without `.env.local` in place. See "Build and test commands" below for how the two relate. |
| `.env.local.example` | Tracked template for `.env.local` (gitignored) — sets `RB_SYS_CARGO_PROFILE=dev` so `bin/setup` (see below) makes the dev Cargo profile the local default. |
| `.standard.yml` | StandardRB config — see its `ruby_version:` field for the Ruby version StandardRB targets. StandardRB wraps RuboCop internally; there is no separate `.rubocop.yml`. |
| `hk.pkl` | `hk` config (StandardRB + rustfmt + clippy via `hk`'s builtin steps) — scoped to local dev only. `bin/setup` installs `hk` (via `Brewfile`) and runs `hk install` to wire up a `git commit` pre-commit hook from this config. Neither `bin/lint` (the cpb-harness PostToolUse hook, see below) nor CI shell out to `hk` — both run the same underlying tools directly instead, since `hk`'s Pkl config needs to fetch its schema package from a GitHub release on every invocation, which isn't reliable in sandboxed/network-restricted environments (CI, remote/web sessions). |
| `.github/workflows/main.yml` | CI: on the Ruby version(s) in the `ruby:` matrix, sets up Rust via `dtolnay/rust-toolchain` pinned to a specific version (with `clippy`/`rustfmt` components) tracking the Claude Code Web sandbox's pre-installed Rust — see the "Set up Rust" step's `toolchain:` input for the exact version — then runs `cargo fmt --check` and `cargo clippy -- -D warnings` against `ext/duckling/`, then `bundle exec rake`. Runs for every push to `main` and every PR. |
| `.github/workflows/release.yml` | Tag-triggered release: gates on CI and the cross-compile workflow, builds the `ruby` source gem, pushes it plus the `x86_64-linux`/`x86_64-darwin` binary gems (downloaded from `cross-gem.yml`) to RubyGems, and cuts a GitHub release. See "Gem release conventions" below. |
| `.github/workflows/cross-gem.yml` | Reusable workflow (`workflow_call`/`workflow_dispatch`) that cross-compiles the native extension for `x86_64-linux` and `x86_64-darwin` via `oxidize-rb/actions/cross-gem` (a wrapper around `rb-sys-dock`/`rake-compiler-dock`) and uploads each as a `native-gem-<platform>` artifact. Called from `release.yml`; not run on every PR (Docker image pulls are large) — trigger manually with `gh workflow run cross-gem.yml --ref <branch>` to smoke-test cross-compilation before a release. |
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
- **`Cargo.toml`**: `cdylib` crate type, depends on `magnus` (`"0.8"`), the wrapped `duckling` crate (`"0.4"`), `chrono`, and `rb-sys` (`default-features = false, features = ["stable-api-compiled-fallback"]` — avoids needing libclang/bindgen on the build machine, and is also what makes single-binary-per-platform precompiled gems possible, see "Build model" below); see `ext/duckling/Cargo.toml` for exact version constraints.
  - **Do not use `magnus = "0.9"`** — despite what some early design docs assumed, 0.9 has never been published to crates.io (only 0.8.2 is released as of this writing); pinning `"0.9"` will fail to resolve. The 0.8.2 API creates symbols via `ruby.to_symbol("key")`, not the 0.9-only `ruby.sym("key")`. Everything else (scan_args, get_kwargs, function!, RHash::aset, Ruby::ary_new, hash_new, chrono FixedOffset IntoValue) is unchanged between 0.8.2 and 0.9. Before trusting a magnus API claim from design docs, spot-check it against the actual published source (`~/.cargo/registry/src/index.crates.io-*/magnus-0.8.2/`).
- **Build model** (issue #43): ships as a `ruby` source gem plus precompiled `x86_64-linux` and `x86_64-darwin` binary gems (unversioned — RubyGems' darwin platform matching treats a `nil` OS version as a wildcard, so this installs on any Darwin major version including newer ones) — installers on those two platforms need no Rust toolchain. `Rakefile` uses `RbSys::ExtensionTask` (not plain `Rake::ExtensionTask`) with `ext.cross_compile = true` / `ext.cross_platform = ["x86_64-linux", "x86_64-darwin"]`; the actual cross-compilation happens in `.github/workflows/cross-gem.yml` via `oxidize-rb/actions/cross-gem`, which wraps `rb-sys-dock`/`rake-compiler-dock` and runs the Cargo build inside `rbsys/<platform>` Docker containers (bundling their own Rust + osxcross — no host Rust toolchain needed for cross-compiling). Because `rb-sys`'s `stable-api-compiled-fallback` feature targets Ruby's ABI-stable C API (3.2+), one binary per platform covers every Ruby minor version `duckling.gemspec`'s `required_ruby_version` allows — no per-Ruby-version fat gems. This is intentionally scoped to just these 2 platforms; expanding to the full 6-platform/9-platform matrices anticipated by earlier design docs (musl/arm variants, Windows, JRuby) is a deferred follow-up — extend by appending to `ext.cross_platform` and the `cross-gem.yml` matrix, nothing more structural should be needed.
- **Known gotchas**:
  - `rb_sys` is a runtime gemspec dependency (see `duckling.gemspec` for the version constraint) — needed even for the precompiled binary gems' consumers, since `rb_sys`'s Ruby-side code (not just the Rust crate) is loaded at runtime.
  - CI installs a Rust toolchain via `dtolnay/rust-toolchain` (with `clippy`/`rustfmt` components), pinned via the `toolchain:` input to a specific version tracking the Rust pre-installed in the Claude Code Web sandbox image — see `.github/workflows/main.yml`'s "Set up Rust" step for the exact pinned version. Bump it there (with the SHA comment updated) when the sandbox image's Rust version changes; don't let it float on `stable`, since that can drift out of sync with what an agent can run in the sandbox without an extra install. Then CI runs `cargo fmt --check` + `cargo clippy -- -D warnings` against `ext/duckling/` before `bundle exec rake`. This toolchain is unrelated to `cross-gem.yml`'s Docker-based cross-compilation, which supplies its own Rust inside the container.
  - Third-party actions in `.github/workflows/*.yml` are pinned to full commit SHAs (with the version as a trailing comment, e.g. `actions/checkout@<sha> # vX.Y.Z`), not floating tags — see the workflow files themselves for what's currently pinned. `.github/dependabot.yml`'s `github-actions` ecosystem entry opens PRs to bump these pins; don't hand-edit a `uses:` line back to a bare tag when copying it into new workflows.
  - Cross-compiling locally (`rake 'native_gem[<platform>]'`) requires Docker running; there is no `Brewfile`/CI dependency on it since it's optional for day-to-day dev (only CI's `cross-gem.yml` job and anyone debugging that pipeline need it).

## Gem release conventions

- **Versioning**: SemVer (`MAJOR.MINOR.PATCH`), single source of truth is `Duckling::VERSION` in `lib/duckling/version.rb`, consumed by `duckling.gemspec`.
- **Current state**: `CHANGELOG.md` (Keep a Changelog format) and the tag-triggered release pipeline (issue #4) are both live on `main`. `rake release` no longer runs the stock `bundler/gem_tasks` flow — the `Rakefile` narrows it to just creating and pushing the `vX.Y.Z` git tag (see `release:guard_clean`/`release:source_control_push`), since building and pushing the `.gem` is now CI's job (issue #24). The README's "release a new version" section documents this flow.
- **Tag-triggered pipeline**: pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which:
  1. Re-runs the main CI workflow (`main.yml`) as a gate — release only proceeds if it's green.
  2. Runs `.github/workflows/cross-gem.yml` to cross-compile the `x86_64-linux` and `x86_64-darwin` binary gems (see "Build model" above), uploading each as a `native-gem-<platform>` artifact.
  3. Verifies the pushed tag matches `Duckling::VERSION` exactly; fails the build on mismatch.
  4. Downloads the two native-gem artifacts into `pkg/`, builds the `ruby` source gem into `pkg/` alongside them, `gem push`es all three (via `RUBYGEMS_API_KEY` secret), and creates a GitHub release attaching all three with `gh release create ... --generate-notes`.
  5. Appends a dated entry to `CHANGELOG.md` by committing to a `changelog/vX.Y.Z` branch, opening a PR (`gh pr create`), and auto-merging it (`gh pr merge --auto --squash`) — it does **not** push to `main` directly, since `main` requires PRs (see below).
  - **Release trigger going forward**: bump `Duckling::VERSION`, merge to `main`, then push a matching `vX.Y.Z` tag.
  - **Smoke-testing the cross-compile step before a release**: `gh workflow run cross-gem.yml --ref <branch>` runs the same cross-compilation `release.yml` depends on, without needing a tag push.
- **Branch protection on `main`** (issue #11): direct pushes are blocked — all changes, including the release pipeline's CHANGELOG commit, land via PR. Merging requires the CI status check to pass — named `Ruby <version>`, where `<version>` comes from the `ruby:` matrix in `main.yml`; branch deletion and force-pushes are disabled. No required review count (single-maintainer repo), so PRs merge as soon as CI is green.
- **Tag ruleset** (issue #12): a GitHub tag ruleset named "Protect release tags" restricts creation/update of `v*.*.*` tags to repo admins, so only authorized pushers can trigger the pipeline above. Configured via `.github/scripts/apply-tag-ruleset.sh` (`gh api repos/{owner}/{repo}/rulesets`) — re-run that script to change the ruleset rather than editing it by hand in the GitHub UI, so the config stays reviewable in version control. Signing tags is out of scope (deferred).

## `bin/` scripts (dev-workflow tooling, not part of the gem)

These come from the cpb Claude Code plugin's harness (commit `d69ba38`) and manage git worktrees / tmux / GitHub PR workflow for *this development environment* — they are not part of what ships in the gem and shouldn't be touched when working on the gem's actual functionality:

- `bin/worktree` — large CLI (`add`, `cd`, `harness`, `cleanup`, `heal-poll`, etc.) for creating per-issue git worktrees and driving Claude/Gemini sessions in tmux.
- `bin/check-worktree` — PreToolUse hook that blocks `Edit`/`Write` when on the `main` branch, steering you toward `bin/worktree add <branch>` instead.
- `bin/claude-code-web-setup` — PreToolUse hook for remote/web Claude Code sessions. Before each `Edit`/`Write`, just-in-time installs gems (`bundle install`) and compiles the native extension (`bundle exec rake compile`) — each step cached via receipt files in `tmp/claude-web-receipts/` so it's a no-op after the first call per session. Does not provision `hk`: `bin/lint` (see above) calls the underlying lint tools directly, so remote sessions never need `hk` installed — it's local-dev-only (see `hk.pkl`/`Brewfile` above). The gems/extension installers live in `bin/claude-web-deps.sh` (sourced, not directly executable); `bin/test` shares its `install_gems` installer (called unconditionally, any-args or no-args) since Bash tool calls don't trigger this Edit/Write-gated hook — `bin/test` no longer needs `compile_extension` itself, since `bundle exec rake test`'s `:compile` prerequisite handles that.

## Keeping this file current

This file is manually maintained — there is no auto-generation. When you land
a PR that changes any of the following, **propose an update to AGENTS.md as
part of that PR** (don't leave it for someone else):

- Directory layout (new top-level dirs, moved files)
- Build/test commands (`bin/test`, `bin/lint`, `Rakefile` tasks)
- The Rust/Magnus wiring (`Cargo.toml`, `extconf.rb`, CI Rust toolchain setup, cross-compilation config) — keep the "Rust/Magnus wiring" section in sync with the actual, verified file contents
- The release process (`Rakefile` `release` task, `.github/workflows/release.yml`, `.github/workflows/cross-gem.yml`) — keep "Gem release conventions" above in sync with the actual, verified workflow behavior
- Version numbers for tools/crates/gems — these belong in their own config files (`duckling.gemspec`, `ext/duckling/Cargo.toml`/`Cargo.lock`, `.standard.yml`, `hk.pkl`, CI workflow matrices), not here. If you need to reference a version, point to the file/field that holds it rather than copying the number, so this doc can't go stale when Dependabot or a manual bump changes it.

If you're an agent and notice this file is out of date with what you just
observed in the repo, fix it in the same PR rather than working around the
discrepancy silently.
