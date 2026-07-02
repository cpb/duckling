# frozen_string_literal: true

require "test_helper"
require "async"

# Empirically tests the claim (from the FFI risk analysis) that a blocking
# `Duckling.parse` call — because it's a synchronous Rust FFI call that does
# not release the GVL — stalls every other Fiber sharing the same
# Falcon/async-gem reactor thread for the duration of the call. This is a
# different failure mode than Puma's OS-thread model, where the GVL is
# contended but the scheduler can still preempt between bytecode
# instructions; an `async` reactor cooperatively schedules Fibers on a
# *single* OS thread, so it depends entirely on Ruby code yielding (e.g. via
# `Task#sleep`, IO wait) to let other Fibers run. A GVL-held native call
# never yields to the reactor at all.
#
# The test spins up an Async::Reactor with:
#   - a "ticker" Fiber that sleeps a short async interval in a loop and
#     records the wall-clock gap between successive ticks
#   - a "parser" Fiber that calls Duckling.parse once, against a
#     representative long LLM-generated paragraph, partway through the
#     ticker's run
#
# If the reactor is never blocked, every ticker gap should stay close to the
# requested sleep interval. If Duckling.parse blocks the whole reactor
# thread, one ticker gap should balloon to roughly the parse call's
# duration.
#
# Hill-first framing: this test asserts the falsifying / non-blocking null
# hypothesis (the largest observed ticker gap stays within a small tolerance
# of the requested sleep interval). If the blocking claim is true, this
# assertion fails, and the failure message reports the measured gap and the
# measured Duckling.parse duration side by side — that failure message *is*
# the empirical result this hill exists to produce.
class FalconFiberBlockingTest < Minitest::Test
  # A few hundred words of representative LLM-generated prose, chosen to
  # contain a mix of dates, times, durations, numbers, and money amounts so
  # Duckling.parse has realistic entity-extraction work to do (not just a
  # cheap no-match scan). Matches the "long LLM-generated paragraph" shape
  # referenced in the FFI risk analysis (~3ms estimated parse time).
  LONG_PARAGRAPH = <<~TEXT.tr("\n", " ").strip
    Thank you for reaching out about your upcoming trip. Based on our
    conversation, I've put together a summary of the itinerary we discussed
    on March 3rd, 2013. Your flight departs tomorrow morning at 7:45am and
    arrives approximately three hours and twenty minutes later, so plan to
    land around 11am local time. The hotel reservation runs from March 5th
    to March 9th, four nights total, at a rate of $189.50 per night, which
    comes to about $758 before taxes and fees. We recommend arriving at the
    airport at least two hours early, so please plan to leave your house no
    later than 5:15am. If you need to reschedule, cancellations made more
    than 48 hours in advance incur no penalty, but anything within 24 hours
    of departure is subject to a $75 fee. Next Monday at 3pm we have a call
    scheduled to confirm ground transportation; if that time doesn't work,
    we're also free next Tuesday between 9am and noon, or any weekday
    afternoon next week. The rental car pickup is scheduled for 12:30pm on
    the day you land, and needs to be returned by 6pm on your departure day
    to avoid an extra $45 late fee. Please also note that the conference
    registration deadline is in two weeks, on March 17th, and early bird
    pricing of $299 expires this Friday at midnight. Let me know if you have
    any questions, and I'll follow up again in about ten days to confirm
    final details. Thanks again, and safe travels on your six hour and
    fifteen minute journey.
  TEXT

  REFERENCE_TIME = Time.new(2013, 2, 12, 4, 30, 0, "-02:00").to_i

  # How often the ticker Fiber is asked to wake up.
  TICK_INTERVAL = 0.001 # 1ms

  # How many ticks to record before/after triggering the parse call, so we
  # get a baseline of "normal" gaps as well as the gap(s) that occur while
  # Duckling.parse is running.
  TICKS_BEFORE_PARSE = 20
  TICKS_AFTER_PARSE = 20

  # Ticker gaps are allowed to exceed TICK_INTERVAL by this much before we
  # consider them "blocked" — real async scheduling always has some jitter
  # (OS scheduling, GC, etc.), so a tiny tolerance avoids false positives on
  # a merely-slow tick.
  NON_BLOCKING_TOLERANCE = 0.010 # 10ms

  def test_duckling_parse_does_not_stall_other_fibers_in_async_reactor
    # Warm up outside the timed reactor run: Duckling.parse's first call per
    # process pays a one-time lazy-static/regex-compilation cost that isn't
    # representative of steady-state request-handling latency (the scenario
    # this test is actually measuring).
    Duckling.parse("tomorrow", locale: "en", reference_time: REFERENCE_TIME)

    tick_gaps = []
    parse_duration = nil
    parse_started_at = nil

    Sync do
      # Ticker task: records the wall-clock gap between successive ticks for
      # the entire run, including the window during which the parser task is
      # executing Duckling.parse.
      ticker = Async do |task|
        last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        (TICKS_BEFORE_PARSE + TICKS_AFTER_PARSE).times do
          task.sleep(TICK_INTERVAL)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          tick_gaps << (now - last)
          last = now
        end
      end

      # Parser task: waits for the ticker to establish a baseline rhythm,
      # then makes a single blocking Duckling.parse call against a
      # representative long paragraph, and records how long it actually
      # took.
      parser = Async do |task|
        task.sleep(TICK_INTERVAL * TICKS_BEFORE_PARSE)
        parse_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # `dims` intentionally omitted: only the `"time"` dimension is
        # implemented as of this gem version (see ext/duckling/src/lib.rs),
        # so this exercises the same code path `dims: ["time"]` would.
        Duckling.parse(
          LONG_PARAGRAPH,
          locale: "en",
          reference_time: REFERENCE_TIME
        )
        parse_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - parse_started_at
      end

      ticker.wait
      parser.wait
    end

    refute_nil parse_duration, "Duckling.parse never completed inside the reactor"
    refute_empty tick_gaps, "ticker task never recorded any gaps"

    max_gap = tick_gaps.max

    assert_operator max_gap, :<, (TICK_INTERVAL + NON_BLOCKING_TOLERANCE),
      "Expected every ticker Fiber tick inside the Async::Reactor to stay " \
      "within #{(TICK_INTERVAL + NON_BLOCKING_TOLERANCE).round(4)}s of the " \
      "requested #{TICK_INTERVAL}s interval (i.e. Duckling.parse does NOT " \
      "stall sibling Fibers), but the largest observed gap was " \
      "#{max_gap.round(4)}s, while the measured Duckling.parse call itself " \
      "took #{parse_duration.round(4)}s. A max gap approximately equal to " \
      "the parse duration is exactly the signature predicted by the " \
      "blocking-FFI-call risk claim: Duckling.parse holds the GVL for its " \
      "entire native execution and never yields to the async reactor, so " \
      "the ticker Fiber (and every other Fiber on this reactor thread) is " \
      "frozen for the duration of the parse call."
  end
end
