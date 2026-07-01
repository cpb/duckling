# extconf.rb Pattern

## Current state

`ext/duckling/extconf.rb` exists in the gem but is empty (0 bytes). The
gemspec already declares `spec.extensions = ["ext/duckling/extconf.rb"]`, so
RubyGems and rake-compiler know to invoke it.

## Verified reference: rust_blank example

Source: [`examples/rust_blank/ext/rust_blank/extconf.rb`](https://github.com/matsadler/magnus/blob/4e46772050e47cd6cd988fa935263cc5c583e388/examples/rust_blank/ext/rust_blank/extconf.rb)

Exact content:

```ruby
require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("rust_blank/rust_blank")
```

Three lines. This is the complete file.

## What create_rust_makefile does

`create_rust_makefile` is provided by the `rb_sys` gem (version 0.9.128 in
Gemfile.lock). It:

1. Locates the Cargo workspace/crate in the same directory as `extconf.rb`
2. Generates a `Makefile` that delegates to `cargo build`
3. Sets `CARGO_BUILD_TARGET` and Ruby-specific environment variables so the
   native extension links against the currently running Ruby

The string argument `"rust_blank/rust_blank"` is the output path for the
compiled shared library relative to `lib/`. So `"duckling/duckling"` would
produce `lib/duckling/duckling.bundle` (macOS) or `lib/duckling/duckling.so`
(Linux).

This file is generated during `rake compile` and also during `gem install`
when the gem is installed from source. RubyGems invokes `extconf.rb` via
`ruby extconf.rb`, which writes the Makefile, and then `make` is run in the
extension directory.

## Content needed for ext/duckling/extconf.rb

```ruby
require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("duckling/duckling")
```

The argument `"duckling/duckling"` matches:
- The `lib_dir = "lib/duckling"` setting in Rake::ExtensionTask (see
  rakefile-setup.md)
- The `require "duckling/duckling"` call expected inside `lib/duckling.rb`

## Relationship to gemspec

`duckling.gemspec` declares:
```ruby
spec.extensions = ["ext/duckling/extconf.rb"]
spec.add_dependency "rb_sys", "~> 0.9.39"
```

The `rb_sys` runtime dependency is what provides `rb_sys/mkmf` to end-users
who install the gem from source. Gemfile.lock pins `rb_sys` to `0.9.128`.

## Open Questions

1. **Does `create_rust_makefile` need Cargo in PATH at gem install time?**
   Yes — the Makefile it generates invokes `cargo build`. End-users installing
   from source must have Rust/Cargo installed. Pre-compiled binary gems (see
   ci-configuration.md) bypass this requirement.

2. **Does rb_sys/mkmf need to be required before mkmf?** The rust_blank example
   requires `mkmf` first, then `rb_sys/mkmf`. This ordering should be followed.
