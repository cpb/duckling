require "mkmf"
require "rb_sys/mkmf"

# rbsys/<platform> cross-compile Docker images bake RUST_TARGET/
# CARGO_BUILD_TARGET into the environment *and* a matching `target = ...`
# into $CARGO_HOME/config.toml, so a bare `cargo build` targets that image's
# own platform by default even with those env vars unset. But
# Rake::ExtensionTask *always* also runs one unconditional "local"
# (non-cross) compile pass using the container's own host Ruby, regardless
# of what's actually being cross-compiled -- and since that pass inherits
# every one of the image's sticky defaults, its Cargo invocation ends up
# targeting the image's foreign platform while its linker selection (driven
# by rake-compiler's own, separate platform reasoning) stays host-native,
# producing a mismatched build that fails to link. That local pass's
# working directory encodes the platform rake-compiler thinks it's building
# (tmp/<platform>/...), so only when it disagrees with RUBY_TARGET do we
# override Cargo's target with the genuine host triple (`rustc -vV`'s
# `host:` line), which beats config.toml's file-based default in rb_sys's
# own target lookup order (env vars, then config.toml).
if (ruby_target = ENV["RUBY_TARGET"]) && !Dir.pwd.include?("/#{ruby_target}/")
  host_target = `rustc -vV`[/^host: (\S+)$/, 1]
  ENV["CARGO_BUILD_TARGET"] = host_target if host_target
  ENV.delete("RUST_TARGET")
end

create_rust_makefile("duckling/duckling")
