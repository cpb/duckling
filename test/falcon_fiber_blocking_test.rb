# frozen_string_literal: true

require "test_helper"
require "async"

# Regression test for issue #38/#64. Before #64, `Duckling.parse` was a
# synchronous Rust FFI call that held the GVL for its entire native
# execution, so it stalled every other Fiber sharing the same
# Falcon/async-gem reactor thread for the duration of the call (empirically
# confirmed by this test's original hill run: max ticker gap ~= the full
# parse duration). This is a different failure mode than Puma's OS-thread
# model, where the GVL is contended but the scheduler can still preempt
# between bytecode instructions; an `async` reactor cooperatively schedules
# Fibers on a *single* OS thread, so it depends entirely on Ruby code
# yielding (e.g. via `Task#sleep`, IO wait) to let other Fibers run.
#
# Since #64, `Duckling.parse` dispatches the GVL-releasing `Native.parse`
# through a background Thread, whose Thread#value block/unblock hooks let
# the calling Fiber yield to the reactor. This test now guards that fix.
#
# The test spins up an Async::Reactor with:
#   - a "ticker" Fiber that sleeps a short async interval in a loop and
#     records the wall-clock gap between successive ticks
#   - a "parser" Fiber that calls Duckling.parse once, against a
#     representative long LLM-generated paragraph, partway through the
#     ticker's run
#
# The blocking signature is a max ticker gap comparable to the parse
# duration itself (pre-#64 measurement: gap ~= 100% of the parse). The
# assertion is therefore proportional — the largest gap must stay well
# below the measured parse duration — rather than an absolute few-ms bound,
# so ordinary scheduling jitter or a GC pause on a loaded CI runner can't
# produce a spurious failure that would be misread as a reactor stall.
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

  # How often the ticker Fiber is asked to wake up.
  TICK_INTERVAL = 0.001 # 1ms

  # How many ticks to record before/after triggering the parse call, so we
  # get a baseline of "normal" gaps as well as the gap(s) that occur while
  # Duckling.parse is running.
  TICKS_BEFORE_PARSE = 20
  TICKS_AFTER_PARSE = 20

  # A reactor stall shows up as a ticker gap comparable to the parse
  # duration (the pre-#64 hill measured gap ~= 100% of the parse). Gaps up
  # to this fraction of the measured parse duration are attributed to
  # scheduling jitter/GC instead of blocking — proportional, so a slow CI
  # runner stretches the allowance along with the parse it's timing.
  BLOCKING_FRACTION = 0.5

  # Floor for the allowance on machines where the parse itself is very
  # fast, so ordinary jitter (OS scheduling, GC pauses) on a loaded runner
  # can't fail the test on its own.
  MIN_GAP_ALLOWANCE = 0.025 # 25ms

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
    allowance = [TICK_INTERVAL + (parse_duration * BLOCKING_FRACTION), MIN_GAP_ALLOWANCE].max

    assert_operator max_gap, :<, allowance,
      "Expected every ticker Fiber tick inside the Async::Reactor to stay " \
      "well below the measured Duckling.parse duration " \
      "(#{parse_duration.round(4)}s; allowance #{allowance.round(4)}s), " \
      "but the largest observed gap was #{max_gap.round(4)}s. A max gap " \
      "comparable to the parse duration is the reactor-stall signature the " \
      "pre-#64 hill measured, when Duckling.parse held the GVL for its " \
      "entire native execution and never yielded to the reactor. Since " \
      "#64, Duckling.parse dispatches the GVL-releasing Native.parse " \
      "through a background Thread precisely so sibling Fibers keep " \
      "running — a failure here means that fix has regressed (or the " \
      "runner is pathologically overloaded; the allowance scales with the " \
      "measured parse duration to make that unlikely)."
  end
end
