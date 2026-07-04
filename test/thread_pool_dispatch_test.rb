# frozen_string_literal: true

require "test_helper"

# Approximates the Puma request-handling model: a fixed pool of plain OS
# threads (no Fiber scheduler installed) each serving "requests" that call
# Duckling.parse. This same shape also covers Sidekiq — its processor is
# likewise a plain thread pool with no Fiber scheduler — so there is no
# distinct Sidekiq scenario to test: from Duckling.parse's point of view the
# two are identical (GVL-holding Ruby threads, no reactor to yield to).
#
# In this model the GVL release inside Duckling::Native.parse is already
# sufficient for concurrency: while one pool thread is inside the native
# call, the others run Ruby. The extra Thread.new per call that #64 added
# buys these callers nothing — no reactor exists to yield to — and costs a
# thread spawn+join per parse (the PR's own benchmarks record +53% to +965%
# per-call overhead, and objects/call 28 → 35 with minor GC 1 → 62).
#
# This test encodes the desired dispatch rule: when the calling thread has
# no Fiber scheduler, Duckling.parse must not spawn a per-call Thread
# (e.g. `Fiber.scheduler ? Thread.new { ... }.value : Native.parse(...)`).
# It currently fails: every call spawns exactly one Thread.
class ThreadPoolDispatchTest < Minitest::Test
  POOL_SIZE = 4
  REQUESTS_PER_WORKER = 5

  # Instruments Thread.new so the test can count spawns that happen while a
  # worker is inside Duckling.parse. Prepended once; counting is scoped by
  # the thread-local flag so other tests (and the pool threads themselves)
  # are unaffected.
  module SpawnCounter
    class << self
      attr_accessor :installed
    end

    def new(...)
      counter = Thread.current[:duckling_spawn_counter]
      counter&.increment
      super
    end
  end

  class Counter
    def initialize
      @count = 0
      @mutex = Mutex.new
    end

    def increment
      @mutex.synchronize { @count += 1 }
    end

    def count
      @mutex.synchronize { @count }
    end
  end

  def setup
    unless SpawnCounter.installed
      Thread.singleton_class.prepend(SpawnCounter)
      SpawnCounter.installed = true
    end
  end

  def test_plain_thread_pool_callers_pay_no_per_call_thread_spawn
    skip "test requires no ambient Fiber scheduler" if Fiber.scheduler

    counter = Counter.new
    results = Array.new(POOL_SIZE)

    workers = POOL_SIZE.times.map do |i|
      Thread.new do
        # Count only Thread.new calls made *from inside* this worker while
        # it is parsing — i.e. dispatch overhead attributable to
        # Duckling.parse itself, not the pool's own setup.
        Thread.current[:duckling_spawn_counter] = counter
        results[i] = REQUESTS_PER_WORKER.times.map do
          Duckling.parse("tomorrow at 3pm", locale: "en")
        end
      ensure
        Thread.current[:duckling_spawn_counter] = nil
      end
    end
    workers.each(&:join)

    results.each do |worker_results|
      worker_results.each do |entities|
        refute_empty entities, "parse results must be unaffected by dispatch"
      end
    end

    assert_equal 0, counter.count,
      "Expected Duckling.parse to spawn no per-call Threads when the " \
      "caller has no Fiber scheduler (a Puma/Sidekiq-style plain thread " \
      "pool already gets concurrency from Native.parse's GVL release " \
      "alone), but #{counter.count} Thread(s) were spawned across " \
      "#{POOL_SIZE * REQUESTS_PER_WORKER} calls — a spawn+join tax on " \
      "every synchronous caller to serve the async-reactor minority."
  end
end
