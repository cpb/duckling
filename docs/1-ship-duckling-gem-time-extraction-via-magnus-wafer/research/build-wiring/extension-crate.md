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

The crate is NOT published to crates.io. Its Cargo.toml references
`repository = "https://github.com/wafer-inc/duckling"` and
`documentation = "https://docs.rs/duckling"`, but no version of this
wafer-inc fork appears on crates.io under that name.

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
duckling = { path = "../../path/to/wafer-inc-duckling" }  # see Open Questions
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

1. **Path vs. git dependency for wafer-inc-duckling**: wafer-inc-duckling is not
   on crates.io. The local path is
   `/Users/cpb/projects/duks/wafer-inc-duckling`. For the gem to be installable
   by others, either: (a) wafer-inc-duckling must be published to crates.io, or
   (b) referenced as a git dependency (e.g.
   `{ git = "https://github.com/wafer-inc/duckling" }`), or (c) vendored into
   the gem repo. A local path dep works for development only.

2. **Does wafer-inc-duckling need to be published to crates.io before the gem
   can be published?** Yes, if using a path dependency. A git dependency
   sidesteps this for source gems, but `cargo package` may reject git
   dependencies with `--locked` unless the git rev is pinned.

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
