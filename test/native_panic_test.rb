# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# What does a panic inside duckling::parse do to a Ruby caller?
#
# The extension catches native panics (ext/duckling/src/lib.rs,
# parse_without_gvl) and re-raises them via `panic_error`, which currently
# uses `rb_eFatal` — matching magnus's own Error::from_panic convention, but
# unrescuable: `fatal` is not a StandardError (it isn't even rescuable via
# `rescue Exception`), and since #64 it must additionally propagate out of
# Duckling.parse's background dispatch Thread through Thread#value.
#
# `Duckling::PanickingNativeFake` (defined by the extension, test-only) has
# Native.parse's signature but its off-GVL callback always panics, routed
# through the same catch_unwind + panic_error path as the real entrypoint.
# Stubbing the Native constant with it drives the public Duckling.parse
# through an authentic panic without needing a real panic-triggering input.
#
# The panic is exercised in a subprocess: if the fatal tears down the
# interpreter (or escapes rescue), only the child dies and the assertion
# reports it — a fatal must never be able to kill the test suite itself.
#
# This test encodes the desired contract — a native panic surfaces to the
# caller as a *rescuable* StandardError (`rescue => e` catches it) — and
# currently fails because panic_error raises `fatal`.
class NativePanicTest < Minitest::Test
  LIB_DIR = File.expand_path("../lib", __dir__)

  PANIC_PROBE = <<~'RUBY'
    require "duckling"

    Duckling.send(:remove_const, :Native)
    Duckling.const_set(:Native, Duckling::PanickingNativeFake)

    begin
      Duckling.parse("tomorrow", locale: "en")
      puts "NO_ERROR"
    rescue => e
      puts "RESCUED #{e.class}: #{e.message}"
    end
    puts "SURVIVED"
  RUBY

  def test_native_panic_surfaces_as_a_rescuable_error
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", LIB_DIR, "-e", PANIC_PROBE
    )

    diagnostics = "probe stdout:\n#{stdout}\nprobe stderr:\n#{stderr}"

    assert status.success?,
      "A duckling::parse panic must not tear down the Ruby process — the " \
      "caller should get a rescuable error, but the probe process exited " \
      "with #{status.exitstatus.inspect}.\n#{diagnostics}"

    assert_includes stdout, "RESCUED",
      "A duckling::parse panic must surface as a StandardError the caller " \
      "can `rescue => e` as ordinary control flow (it already cost the " \
      "caller nothing but that one call), but plain rescue did not catch " \
      "it — panic_error currently raises the unrescuable `fatal` class.\n" \
      "#{diagnostics}"

    assert_includes stdout, "SURVIVED",
      "Execution must continue after rescuing a native panic.\n#{diagnostics}"

    assert_includes stdout, "intentional panic from Duckling::PanickingNativeFake",
      "The panic message must be preserved in the raised error.\n#{diagnostics}"
  end
end
