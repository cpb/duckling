# CI Configuration

## Current CI state

Source: `.github/workflows/main.yml` in this worktree

```yaml
name: Ruby

on:
  push:
    branches:
      - main
  pull_request:

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
      - uses: actions/checkout@v6
        with:
          persist-credentials: false
      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - name: Run the default task
        run: bundle exec rake
```

Missing from this workflow:
- No Rust toolchain installation
- No compile step — `bundle exec rake` currently runs `test` + `standard` only
  (the default task does not include `compile`)

## What needs to change

### 1. Add Rust toolchain setup

Insert before the "Run the default task" step:

```yaml
- name: Set up Rust
  uses: dtolnay/rust-toolchain@stable
```

`dtolnay/rust-toolchain` is the de facto standard action for Rust in CI. The
`@stable` ref pins to the current stable Rust release at workflow run time.

Alternatively, `actions-rust-lang/setup-rust-toolchain` provides caching
of the Cargo registry and build artifacts. For a gem that compiles a non-trivial
crate ([duckling](https://github.com/wafer-inc/duckling) pulls in regex, chrono, serde, serde_json,
once_cell, smallvec), build artifact caching would meaningfully speed up CI.

### 2. Ensure compile runs before tests

Two approaches:

**Option A**: Update the Rakefile default task to include compile (see
rakefile-setup.md), so `bundle exec rake` triggers compile automatically:

```yaml
- name: Run the default task
  run: bundle exec rake
```

This requires `task default: %i[compile test standard]` in the Rakefile.

**Option B**: Add an explicit compile step:

```yaml
- name: Compile native extension
  run: bundle exec rake compile
- name: Run tests and lint
  run: bundle exec rake test standard
```

Option A is cleaner but means local `bundle exec rake` also compiles, which
is slower for lint-only runs. Option B makes the CI steps more explicit.

### 3. apt dependencies

The `stable-api-compiled-fallback` feature for rb-sys uses pre-compiled
bindings and does NOT require libclang or bindgen at build time. The
ubuntu-latest runner should have everything needed (gcc, make, libssl-dev).
No additional `apt-get install` step is expected to be required.

If [duckling](https://github.com/wafer-inc/duckling)'s dependencies introduce a build requirement (e.g.
openssl-sys needs libssl-dev headers), an apt step would be needed. Current
[duckling](https://github.com/wafer-inc/duckling) dependencies (regex, chrono, serde, etc.) are pure Rust
and have no known system library requirements.

## Rust version pinning

### Magnus workspace rust-toolchain.toml

Correction: the local magnus checkout used during this research had an
untracked `rust-toolchain.toml` (confirmed via `git status` — not present in
[matsadler/magnus](https://github.com/matsadler/magnus) upstream). Magnus
itself does **not** pin a toolchain version; the file below was a local
artifact, not sourced from the project:

```toml
[toolchain]
channel = "1.94.1"
components = [
    "rustfmt",
    "clippy",
    "rust-src",
]
```

The extension crate could still adopt a pinned-toolchain approach
independently — see the recommendation below.

### Recommended approach for duckling gem

Adding a `rust-toolchain.toml` to the gem root:

```toml
[toolchain]
channel = "stable"
```

Using `"stable"` rather than a pinned version means CI always builds against
the current stable toolchain, which is lower maintenance. Pinning to a specific
version (e.g. `"1.85.0"`) is useful to avoid surprise breakage from toolchain
changes but requires manual bumps.

The minimum Rust version required: Magnus 0.9.0 declares
`rust-version = "1.85"` in its Cargo.toml (the `edition = "2024"` requirement).
Any toolchain at 1.85+ will work.

The `rust_blank` example does not include its own `rust-toolchain.toml` — it
inherits the one from the magnus workspace root. The gem needs its own file
since it is not part of the magnus workspace.

## Publishing: source gem vs. pre-compiled binaries

### Source gem (current path)

A source gem requires every installer to have Rust and Cargo installed. The
gem installs by running `extconf.rb` → `cargo build` on the user's machine.

Pros:
- Simple — no cross-compilation infrastructure needed
- Works for any platform/architecture at install time

Cons:
- Users must have Rust toolchain installed (unusual requirement for a Ruby gem)
- Compile time at install: [duckling](https://github.com/wafer-inc/duckling) is a non-trivial crate
- `bundle exec rake compile` required before running tests locally

### Pre-compiled binary gems (rake-compiler-dock)

Gemfile.lock already includes `rake-compiler-dock (1.12.0)` (pulled in by
rb_sys 0.9.128). This is the tooling used to cross-compile gems for multiple
platforms inside Docker containers.

Pre-compiled binary gems ship platform-specific `.so`/`.bundle` files embedded
in the gem. Installers on supported platforms skip compilation entirely.

Typical target platforms for a Ruby gem:
- `x86_64-linux` (most Linux servers)
- `aarch64-linux` (ARM Linux, e.g. AWS Graviton)
- `x86_64-darwin` (Intel Mac)
- `arm64-darwin` (Apple Silicon Mac)
- `x64-mingw-ucrt` (Windows)

To produce these, the gem would add a `lib/tasks/gem.rake` (or Rakefile
additions) that run `rake-compiler-dock` to build each platform gem, then
`gem push` each one.

### Recommendation for 0.2.0

Shipping as a source-only gem for the initial release is reasonable:
- Simpler release process
- No CI cross-compilation infrastructure to set up
- The rb_sys gem and rake-compiler-dock are already in Gemfile.lock for when
  binary gems become desirable

Document the Rust/Cargo requirement prominently in the README for 0.2.0 users.

## Open Questions

1. **Which CI action for Rust?** `dtolnay/rust-toolchain@stable` vs.
   `actions-rust-lang/setup-rust-toolchain`. The latter provides Cargo registry
   and build artifact caching. Evaluate whether build time in CI justifies the
   caching complexity.

2. **Cargo cache in CI**: Without caching, every CI run recompiles
   [duckling](https://github.com/wafer-inc/duckling) and all its transitive dependencies from source. A
   `~/.cargo/registry` cache would reduce this significantly. `ruby/setup-ruby`
   with `bundler-cache: true` already caches the Ruby side; Rust needs separate
   caching (either via `actions-rust-lang/setup-rust-toolchain` or a manual
   `actions/cache` step).

3. **Git dependency in Cargo.toml**: If [duckling](https://github.com/wafer-inc/duckling) is referenced as a
   git dependency, Cargo will clone it on every CI run unless the
   `~/.cargo/git` directory is cached.

4. **actions/checkout@v6**: The current workflow uses `v6`, which is not a
   released version as of this writing (v4 is current). This may be a typo in
   the existing workflow. Verify whether this resolves correctly or if it should
   be pinned to `v4`.
