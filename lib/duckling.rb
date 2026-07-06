# frozen_string_literal: true

require_relative "duckling/version"
require_relative "duckling/duckling"

module Duckling
  # Native.parse already releases the GVL around the native call, but a bare
  # GVL release alone does not hand control back to an Async::Reactor —
  # Ruby 3.4's Fiber::Scheduler#blocking_operation_wait auto-offload path
  # requires a flag rb_thread_call_without_gvl never sets. Spawning a real
  # background Thread lets the calling Fiber yield to the reactor via
  # Thread#value's block/unblock scheduler hooks instead, which have been
  # present since Ruby 3.0. See
  # https://github.com/cpb/duckling/wiki/research-fiber-scheduler-mechanism-spike
  # for the empirical result driving this.
  #
  # Only worth paying for when a Fiber scheduler is actually installed on the
  # calling thread: a plain thread pool (Puma/Sidekiq-style, no reactor to
  # yield to) already gets its concurrency from Native.parse's own GVL
  # release, so the extra Thread.new there is a pure spawn+join tax. Calling
  # Native.parse directly (no thread) is also the benchmark suite's baseline
  # for measuring the dispatch overhead itself.
  #
  # report_on_exception is disabled from the very first line inside the
  # spawned thread (not set on the Thread object afterward, which would race
  # a fast-failing call) so a rescued error doesn't also print a
  # thread-termination backtrace to stderr — Thread#value still re-raises it
  # to the caller as ordinary control flow.
  #
  # reference_time: is coerced here, not in the native extension:
  # Native.parse's Magnus binding only accepts a strict kind_of?(Time) (issue
  # #45), which rejects ActiveSupport::TimeWithZone and stdlib DateTime even
  # though both carry the same to_i/utc_offset a real Time does — #to_time
  # normalizes any of those (and anything else that offers the same
  # conversion) to a real Time before it crosses into Rust.
  #
  # ALTERNATIVE ARCHITECTURE (compare against main's lib/duckling.rb and the
  # issue-75/rust-seam-alt worktree): here, reference_zone: is forwarded to
  # Native.parse as a plain String and Rust does *everything* zone-related
  # itself via chrono-tz (compiled-in IANA tzdata) -- validation, "anchor at
  # current time in zone", and per-date Naive-result resolution (see
  # build_context/resolve_naive in ext/duckling/src/lib.rs). There is no
  # tzinfo runtime dependency in this version at all, and Ruby needs no
  # reference_zone:-specific logic beyond forwarding the string through.
  def self.parse(text, locale: "en", dims: ["time"], reference_time: nil, reference_zone: nil, with_latent: false, &block)
    if reference_time && !reference_time.is_a?(Time) && reference_time.respond_to?(:to_time)
      reference_time = reference_time.to_time
    end

    # reference_time:/reference_zone: are only included when present:
    # Native.parse's Magnus binding treats an explicitly-passed `nil` for its
    # Option<...> kwargs differently from the key being absent entirely (the
    # former raises a TypeError) -- omitting the key is what lets Rust's own
    # None-based defaults apply, same as when a caller never mentions these
    # keywords at all.
    kwargs = {locale: locale, dims: dims, with_latent: with_latent}
    kwargs[:reference_time] = reference_time if reference_time
    kwargs[:reference_zone] = reference_zone if reference_zone

    return Native.parse(text, **kwargs, &block) unless Fiber.scheduler

    Thread.new do
      Thread.current.report_on_exception = false
      Native.parse(text, **kwargs, &block)
    end.value
  end
end
