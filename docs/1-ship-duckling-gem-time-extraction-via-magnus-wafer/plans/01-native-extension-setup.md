# Plan 01: Native Extension Setup

## Decision

Wire the native extension using Magnus 0.9 + rb-sys `stable-api-compiled-fallback`,
mirroring the canonical `rust_blank` example from the Magnus repo. The extension
crate lives at `ext/duckling/` as a `cdylib` that depends on the local
`wafer-inc-duckling` rlib via a Cargo path dependency. No `build.rs` is added to
the extension crate; Magnus's own `build.rs` propagates `rb_sys_env::activate()`
transitively.

## Rationale

- **cdylib + no build.rs**: The verified `rust_blank` example contains no
  `build.rs` at the extension level. Magnus's `build.rs` calls
  `rb_sys_env::activate()` and Cargo propagates link metadata up to the final
  cdylib.
  ([extension-crate.md](../research/build-wiring/extension-crate.md))

- **stable-api-compiled-fallback**: Pre-compiled stable ABI bindings; no bindgen
  or libclang required at build time. Taken directly from the rust_blank
  `Cargo.toml`.
  ([extension-crate.md](../research/build-wiring/extension-crate.md))

- **extconf.rb pattern**: `create_rust_makefile("duckling/duckling")` is the
  complete 3-line pattern from the verified rust_blank example.
  ([extconf-rb.md](../research/build-wiring/extconf-rb.md))

- **Rake::ExtensionTask with lib_dir**: `lib_dir = "lib/duckling"` aligns the
  compiled artifact location with the extconf.rb path argument and the expected
  `require "duckling/duckling"` call.
  ([rakefile-setup.md](../research/build-wiring/rakefile-setup.md))

- **CI Rust toolchain**: `dtolnay/rust-toolchain@stable` is the standard action.
  Magnus 0.9 requires rustc 1.85+ (edition 2024 stabilized there).
  ([ci-configuration.md](../research/build-wiring/ci-configuration.md))

## Steps

### 1. Create `ext/duckling/Cargo.toml`

New file. This is the cdylib extension crate.

```toml
[package]
name = "duckling_ext"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
magnus = { version = "0.9" }
duckling = "0.4"   # crates.io: https://crates.io/crates/duckling
rb-sys = { version = "*", default-features = false, features = ["stable-api-compiled-fallback"] }
```

Notes:
- `edition = "2024"` requires rustc 1.85+; Magnus 0.9 already requires 1.85.
- `duckling = "0.4"` is the crates.io dep — no path dependency needed.
- No `[build-dependencies]` or `build.rs`; Magnus handles rb_sys link metadata.

### 2. Create `ext/duckling/src/lib.rs`

New file. Stub that compiles but registers nothing (bindings added in plan 02).

```rust
use magnus::{Error, Ruby};

#[magnus::init]
fn init(_ruby: &Ruby) -> Result<(), Error> {
    Ok(())
}
```

### 3. Fill `ext/duckling/extconf.rb`

Currently empty (0 bytes). Replace with 3 lines:

```ruby
require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("duckling/duckling")
```

The argument `"duckling/duckling"` places the compiled artifact at
`lib/duckling/duckling.bundle` (macOS) or `lib/duckling/duckling.so` (Linux),
matching the `lib_dir` in step 4 and the require in step 5.

### 4. Update `Rakefile`

Add after existing requires, before the default task:

```ruby
require "rake/extensiontask"

Rake::ExtensionTask.new("duckling") do |ext|
  ext.lib_dir = "lib/duckling"
end
```

Update the default task:

```ruby
task default: %i[compile test standard]
```

Rake executes prerequisites left-to-right, so `compile` runs before `test`.
`Rake::ExtensionTask` is provided by `rake-compiler` (~> 1.2.0), already a
development dependency in `duckling.gemspec`.

### 5. Update `lib/duckling.rb`

Add after the version require:

```ruby
require_relative "duckling/duckling"
```

This loads the compiled `.bundle`/`.so` produced by step 4.

### 6. Update `.github/workflows/main.yml`

Insert a Rust toolchain step between the Ruby setup step and the rake step:

```yaml
- name: Set up Rust
  uses: dtolnay/rust-toolchain@stable
```

No additional apt packages needed: `stable-api-compiled-fallback` uses
pre-compiled bindings, and wafer-inc-duckling's dependencies (regex, chrono,
serde, serde_json, once_cell, smallvec) are pure Rust with no system library
requirements.

## Open Questions

1. ~~**wafer-inc-duckling not on crates.io.**~~ **Resolved**: The crate is
   published on crates.io as `duckling = "0.4"` (https://crates.io/crates/duckling).
   Use `duckling = "0.4"` in Cargo.toml — no path or git dependency needed.
   No crates.io blocker for RubyGems publication.
   ([extension-crate.md](../research/build-wiring/extension-crate.md))

2. **`edition = "2024"` and stable Rust.** Edition 2024 was stabilized in
   Rust 1.85. Magnus 0.9 declares `rust-version = "1.85"`. The
   `dtolnay/rust-toolchain@stable` step installs the current stable release
   (1.85+ as of this writing). Verify this holds in CI before merging.
   ([ci-configuration.md](../research/build-wiring/ci-configuration.md) — Rust
   version pinning section)

3. **`actions/checkout@v6` in existing CI.** v6 is not a published release of
   `actions/checkout` (v4 is current). This may be a forward-looking pin or a
   typo in the existing workflow. Do not change in this plan — leave as-is and
   flag for human review.
   ([ci-configuration.md](../research/build-wiring/ci-configuration.md) — Open
   Question 4)

## Verification

1. `bundle exec rake compile` — must succeed with no errors.

2. `ruby -e "require 'duckling'"` — must not raise `LoadError`.

3. `bundle exec rake test` — existing version test must still pass.

4. Confirm the compiled artifact exists:
   `ls lib/duckling/duckling.{bundle,so}` — one of these must be present after
   compile.
