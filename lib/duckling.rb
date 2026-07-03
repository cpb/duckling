# frozen_string_literal: true

require_relative "duckling/version"
require_relative "duckling/duckling"

module Duckling
  # Thread-per-call dispatch (issue #64): Native.parse already releases the
  # GVL around the native call, but a bare GVL release alone does not hand
  # control back to an Async::Reactor — Ruby 3.4's Fiber::Scheduler
  # #blocking_operation_wait auto-offload path requires a flag
  # rb_thread_call_without_gvl never sets. Spawning a real background Thread
  # lets the calling Fiber yield to the reactor via Thread#value's
  # block/unblock scheduler hooks instead, which have been present since Ruby
  # 3.0. See the wiki's research-fiber-scheduler-mechanism-spike for the
  # empirical result driving this. Call Native.parse directly to skip the
  # thread-spawn (e.g. for benchmarking the dispatch overhead itself).
  def self.parse(...)
    Thread.new { Native.parse(...) }.value
  end
end
