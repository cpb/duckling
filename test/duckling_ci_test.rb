# frozen_string_literal: true

require "test_helper"

class DucklingCiTest < Minitest::Test
  def test_native_extension_infrastructure
    ext_dir = File.join(__dir__, "../ext/duckling")

    assert File.exist?(File.join(ext_dir, "Cargo.toml")),
      "ext/duckling/Cargo.toml must exist — Rust crate not yet set up"

    cargo = File.read(File.join(ext_dir, "Cargo.toml"))
    assert_match(/\[lib\]/, cargo, "Cargo.toml must declare a [lib] section")
    assert_match(/crate-type.*cdylib/, cargo, "Cargo.toml must set crate-type = [\"cdylib\"]")
  end
end
