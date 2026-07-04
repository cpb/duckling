# frozen_string_literal: true

require "test_helper"
require "async"

# Duckling.parse dispatches through Thread.new (issue #64), and
# Thread#report_on_exception defaults to true — so an exception raised by
# Duckling::Native.parse inside that thread prints a full
# "#<Thread…> terminated with exception (report_on_exception is true)"
# backtrace to stderr at thread-termination time, *in addition to*
# Thread#value re-raising it in the caller. That turns every rescued
# bad-input call — a documented, ordinary control-flow path — into stderr
# noise that did not exist before #64, and reads in logs like an unhandled
# crash.
#
# These tests assert the desired behavior: the exception still reaches the
# caller exactly as before, with nothing written to stderr along the way.
class ParseErrorStderrTest < Minitest::Test
  def test_rescued_argument_error_writes_nothing_to_stderr
    error = nil
    _out, err = capture_subprocess_io do
      Duckling.parse("tomorrow", locale: "zz-ZZ")
    rescue ArgumentError => e
      error = e
    end

    refute_nil error, "expected the unsupported-locale ArgumentError to reach the caller"
    assert_empty err,
      "Duckling.parse must not leak a thread-termination backtrace to " \
      "stderr when its error is rescued as normal control flow, but stderr " \
      "received:\n#{err}"
  end

  # Without an installed Fiber scheduler, Duckling.parse (lib/duckling.rb)
  # takes its `Fiber.scheduler ? ... : Native.parse(...)` false branch and
  # never spawns the Thread this whole file is about — so the test above
  # never exercises report_on_exception=false at all, and would pass just
  # as well if that line were deleted. Running the same assertion inside an
  # Async::Reactor (via `Sync`, which installs a Fiber scheduler on the
  # current thread for its duration — see falcon_fiber_blocking_test.rb)
  # forces Duckling.parse through the actual Thread.new path.
  def test_rescued_argument_error_writes_nothing_to_stderr_under_fiber_scheduler
    error = nil
    _out, err = capture_subprocess_io do
      Sync do
        Duckling.parse("tomorrow", locale: "zz-ZZ")
      end
    rescue ArgumentError => e
      error = e
    end

    refute_nil error, "expected the unsupported-locale ArgumentError to reach the caller"
    assert_empty err,
      "Duckling.parse must not leak a thread-termination backtrace to " \
      "stderr when its error is rescued as normal control flow, even when " \
      "dispatched through the background Thread a Fiber scheduler forces " \
      "it to use, but stderr received:\n#{err}"
  end

  def test_error_class_and_message_are_preserved_across_dispatch
    error = assert_raises(ArgumentError) do
      capture_subprocess_io { Duckling.parse("tomorrow", locale: "zz-ZZ") }
    end
    assert_match(/locale/i, error.message)
  end
end
