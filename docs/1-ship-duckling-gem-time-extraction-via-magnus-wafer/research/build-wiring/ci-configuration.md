# CI Configuration

**Re-drafted 2026-07-01.** This document originally described a prospective
CI setup ("what needs to change" before the native extension existed). The
extension has since landed and the gem has shipped through `v0.2.0` — this
version describes what CI and release actually do today, verified against
[`main@03a69e1`](https://github.com/cpb/duckling/tree/03a69e157a1543862c734ca8ac278a84600af315).

## Current CI workflow

Source: [`.github/workflows/main.yml`](https://github.com/cpb/duckling/blob/03a69e157a1543862c734ca8ac278a84600af315/.github/workflows/main.yml)

```yaml
name: Ruby

on:
  push:
    branches:
      - main
  pull_request:
  workflow_call:

permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    name: Ruby ${{ matrix.ruby }}
    strategy:
      matrix:
        ruby:
          - '3.3.6'

    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false
      - name: Set up Ruby
        uses: ruby/setup-ruby@0dafeac902942906541bc140009cdbf32665b601 # v1.315.0
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - name: Set up Rust
        uses: dtolnay/rust-toolchain@4be7066ada62dd38de10e7b70166bc74ed198c30 # stable as of 2026-06-30
        with:
          components: clippy, rustfmt
      - name: Check Rust formatting
        run: cargo fmt --manifest-path ext/duckling/Cargo.toml --check
      - name: Run clippy
        run: cargo clippy --manifest-path ext/duckling/Cargo.toml -- -D warnings
      - name: Run the default task
        run: bundle exec rake
```

This resolves everything the original draft of this document flagged as
missing:
- **Rust toolchain setup** — added via `dtolnay/rust-toolchain`, pinned to a
  specific action commit (comment-dated, not version-pinned — see Open
  Questions below).
- **Compile before test** — resolved via Option A from the original draft:
  the Rakefile's default task is `task default: %i[standard compile test]`
  (see [rakefile-setup.md](./rakefile-setup.md)), so `bundle exec rake`
  compiles before running tests. No separate explicit compile step was
  needed in the workflow.
- **`actions/checkout@v6` typo** — resolved; pinned to `v7.0.0` by commit SHA
  (`dependabot` keeps this current, see `.github/dependabot.yml`).
- **Lint/format for the Rust side** — added `cargo fmt --check` and
  `cargo clippy -- -D warnings` steps, which the original draft didn't
  anticipate at all.
- **`workflow_call` trigger** — added so the release workflow (below) can
  reuse this workflow as its CI gate.

apt dependencies: still none needed. `stable-api-compiled-fallback` for
rb-sys uses pre-compiled bindings; the `ubuntu-latest` runner's default
toolchain (gcc, make, libssl-dev) is sufficient — confirmed empirically, CI
has been green without any `apt-get install` step.

## Release workflow

Source: [`.github/workflows/release.yml`](https://github.com/cpb/duckling/blob/03a69e157a1543862c734ca8ac278a84600af315/.github/workflows/release.yml)

Triggered on `v*.*.*` tag pushes. Reuses `main.yml` as a CI gate
(`uses: ./.github/workflows/main.yml`), then:

1. Verifies the pushed tag matches `Duckling::VERSION` in
   `lib/duckling/version.rb`.
2. Builds a **source gem**: `gem build duckling.gemspec`.
3. Publishes to RubyGems: `gem push duckling-*.gem` (using the
   `RUBYGEMS_API_KEY` secret).
4. Creates a GitHub Release with auto-generated notes.
5. Opens an automated PR appending the release notes to `CHANGELOG.md`.

**The source-gem-only decision from the original draft's recommendation
shipped as-is.** No cross-compilation / pre-compiled binary gem pipeline was
built — `rake-compiler-dock` remains in `Gemfile.lock` only as a transitive
dependency of `rb_sys`, unused for actual multi-platform builds. End users
installing the gem still need a working Rust/Cargo toolchain locally, exactly
as the original draft's "Cons" section for the source-gem path predicted.

Released versions to date: `v0.1.0`, `v0.1.1`, `v0.1.2`, `v0.2.0` (current).

## Rust version pinning

No `rust-toolchain.toml` was ever added to the gem root — the "Recommended
approach" section in the original draft was not adopted. CI instead pins the
`dtolnay/rust-toolchain` **action** to a specific commit SHA (via
`dependabot`), with the action resolving to whatever Rust release is
`stable` at the time that commit was pinned (comment: "stable as of
2026-06-30"). This means the actual `rustc` version CI builds against can
still drift forward across `dependabot` bumps of the action, even though the
action reference itself is pinned — see
[issue #28](https://github.com/cpb/duckling/issues/28) for aligning this
with the Rust version pre-installed in Claude Code Web.

The extension crate's actual `Cargo.toml`
([`ext/duckling/Cargo.toml`](https://github.com/cpb/duckling/blob/03a69e157a1543862c734ca8ac278a84600af315/ext/duckling/Cargo.toml))
also diverged from what earlier research assumed:

```toml
[package]
name = "duckling"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
magnus = { version = "0.8" }
duckling = "0.4"
chrono = "0.4"
rb-sys = { version = "*", default-features = false, features = ["stable-api-compiled-fallback"] }
```

Notably `magnus = "0.8"`, not `"0.9"` — Magnus 0.9 was never published to
crates.io (only 0.8.2 is), so the shipped extension uses 0.8's API
(`Ruby::to_symbol`, not the nonexistent `Ruby::sym`). Several other research
documents in this tree still assume Magnus 0.9.0 from the local checkout used
during research; treat `ext/duckling/Cargo.toml` on `main` as authoritative
over those documents where they conflict.

## Open Questions

Superseded by tracked issues rather than left as inline prose:

- Whether to switch from `dtolnay/rust-toolchain` to
  `actions-rust-lang/setup-rust-toolchain` for Cargo registry/build-artifact
  caching — no cache step exists today; every CI run recompiles `duckling`
  and its transitive dependencies from source. Not yet tracked as an issue;
  worth filing if CI build time becomes a pain point.
- Pinning the Rust version CI uses to what's available in Claude Code Web —
  tracked as [issue #28](https://github.com/cpb/duckling/issues/28).
- Expanding the test matrix beyond Ruby 3.3.6 / current stable Rust —
  tracked as [issue #29](https://github.com/cpb/duckling/issues/29).
