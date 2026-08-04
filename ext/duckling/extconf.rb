require "mkmf"
require "rb_sys/mkmf"

# rbsys/<platform> cross-compile Docker images bake RUST_TARGET/
# CARGO_BUILD_TARGET into the image environment so a bare `cargo build`
# targets that image's own platform by default. But Rake::ExtensionTask
# *always* also runs one unconditional "local" (non-cross) compile pass
# using the container's own host Ruby, regardless of what's actually being
# cross-compiled -- and since that pass inherits the same image-level env
# vars, its Cargo invocation ends up targeting the image's foreign platform
# while its linker selection (driven by rake-compiler's own, separate
# platform reasoning) stays host-native, producing a mismatched build that
# fails to link. That local pass's working directory encodes the platform
# rake-compiler thinks it's building (tmp/<platform>/...), so only trust
# RUST_TARGET/CARGO_BUILD_TARGET when they agree with it.
if (ruby_target = ENV["RUBY_TARGET"]) && !Dir.pwd.include?("/#{ruby_target}/")
  ENV.delete("RUST_TARGET")
  ENV.delete("CARGO_BUILD_TARGET")
end

create_rust_makefile("duckling/duckling")
