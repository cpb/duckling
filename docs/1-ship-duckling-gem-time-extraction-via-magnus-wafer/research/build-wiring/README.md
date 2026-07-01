# Build Wiring Research

How to wire up the native extension so the gem compiles: cdylib crate layout,
extconf.rb content, Rakefile changes, and CI configuration.

## Documents

| File | Description |
|------|-------------|
| [extension-crate.md](extension-crate.md) | The new `ext/duckling/` Rust crate that must be created: cdylib type, Cargo.toml shape, `build.rs` question, and open dependency questions for [duckling](https://github.com/wafer-inc/duckling). |
| [extconf-rb.md](extconf-rb.md) | What `ext/duckling/extconf.rb` must contain, how `create_rust_makefile` works, and how it compares to the verified `rust_blank` example. |
| [rakefile-setup.md](rakefile-setup.md) | The `Rake::ExtensionTask` addition needed in the Rakefile and why `lib_dir = "lib/duckling"` is the right setting. |
| [ci-configuration.md](ci-configuration.md) | CI changes needed: Rust toolchain setup, compile step, Rust version pinning strategy, and the source-gem vs pre-compiled-binary tradeoff. |
