# Extension Crate Layout

## What this covers

The gem needs a dedicated Rust crate at `ext/duckling/` that compiles to a
native shared library (`.so` on Linux, `.bundle` on macOS). This is separate
from the wafer-inc-duckling library crate, which stays as an rlib dependency.

## Verified reference: rust_blank example

Source: `/Users/cpb/projects/duks/magnus/examples/rust_blank/ext/rust_blank/`

The canonical Magnus example for a gem extension crate. Verified file list:

```
ext/rust_blank/
├── Cargo.lock
├── Cargo.toml
├── extconf.rb
└── src/
    └── lib.rs
```

Note: no `build.rs` exists in this example crate. Magnus itself carries the
`build.rs` that calls `rb_sys_env::activate()` (at
`/Users/cpb/projects/duks/magnus/build.rs`), and that runs when the extension
depends on magnus as a crate.

## wafer-inc-duckling crate type

Source: `/Users/cpb/projects/duks/wafer-inc-duckling/Cargo.toml`

```toml
[package]
name = "duckling"
version = "0.4.0"
edition = "2021"
```

There is no `[lib]` section, so the crate-type defaults to `rlib`. It is
suitable as a dependency of the extension crate.

The crate **is published to crates.io as `duckling`** — the package name
matches the crate name. Current crates.io version: **0.4.0** (published
2026-04-16). The local checkout at `/Users/cpb/projects/duks/wafer-inc-duckling`
is also at 0.4.0, matching the published release.

crates.io: https://crates.io/crates/duckling  
Repo: https://github.com/wafer-inc/duckling  
Owner: Andre Popovitch (anchpop)

## Verified Cargo.toml from rust_blank

```toml
[package]
name = "rust_blank"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
magnus = { path = "../../../.." }
# enable rb-sys feature to test against Ruby head. This is only needed if you
# want to work with the unreleased, in-development, next version of Ruby
rb-sys = { version = "*", default-features = false, features = ["stable-api-compiled-fallback"] }
```

Key observations:
- `crate-type = ["cdylib"]` is required — this produces `.so`/`.bundle`
- `edition = "2024"` (Rust 2024 edition)
- rb-sys uses `stable-api-compiled-fallback`: pre-compiled stable ABI bindings;
  no bindgen or libclang required at build time
- No `[build-dependencies]` or `build.rs` — Magnus's own `build.rs` handles
  `rb_sys_env::activate()` transitively when magnus is a dependency

## Template for ext/duckling/Cargo.toml

```toml
[package]
name = "duckling_ext"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
magnus = { version = "0.9", features = ["rb-sys"] }
duckling = "0.4"   # published on crates.io as "duckling" by wafer-inc/anchpop
rb-sys = { version = "*", default-features = false, features = ["stable-api-compiled-fallback"] }
```

The `rb-sys` feature on the magnus dependency unlocks `magnus::rb_sys` utilities
and ensures the correct feature flags are activated in magnus.

## Expected directory structure after setup

```
ext/duckling/
├── Cargo.toml    (cdylib crate, depends on magnus + duckling lib)
└── src/
    └── lib.rs    (#[magnus::init] fn init(...))
```

A `build.rs` may or may not be needed — see Open Questions below.

## Minimal lib.rs skeleton

Based on the rust_blank `#[magnus::init]` pattern:

```rust
use magnus::{Error, Ruby};

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    // Register Ruby classes/methods wrapping wafer-inc-duckling here
    Ok(())
}
```

## Open Questions

1. ~~**Path vs. git dependency**: wafer-inc-duckling is not on crates.io.~~
   **Resolved**: The crate is published on crates.io as `duckling = "0.4"`.
   Use the crates.io dep — no path or git dependency needed. The local checkout
   at `/Users/cpb/projects/duks/wafer-inc-duckling` is the development source
   for the same 0.4.0 release.

2. ~~**Does wafer-inc-duckling need to be published to crates.io?**~~
   **Resolved**: Already published. No crates.io blocker for gem publication.

3. **Is a build.rs needed in ext/duckling/?** The rust_blank example has NO
   `build.rs`. Magnus's own `build.rs` calls `rb_sys_env::activate()`, and
   Cargo propagates link metadata from dependency build scripts up to the final
   binary. This should be sufficient when depending on magnus from crates.io.
   If linking issues appear at compile time, adding a `build.rs` with
   `rb_sys_env::activate()` to the extension crate itself would be the fix.
   Requires adding `rb-sys-env = "0.2"` to `[build-dependencies]`.

4. **Rust edition**: rust_blank uses `edition = "2024"` (requires rustc 1.85+).
   wafer-inc-duckling uses `edition = "2021"`. The extension crate can use
   either, but mixing editions in a workspace is allowed. Using 2024 aligns with
   the Magnus example.
