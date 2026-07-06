# frozen_string_literal: true

require_relative "duckling/version"
require_relative "duckling/duckling"
require "tzinfo"

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
  # reference_zone: is resolved entirely here, not in the native extension:
  # the wrapped wafer-inc-duckling crate (and this gem's own Magnus binding)
  # only understand chrono::FixedOffset, with no IANA zone/DST-transition
  # concept at all, so per-date-correct offsets have to come from a real
  # timezone database on the Ruby side (tzinfo). Native.parse still only ever
  # sees a single reference_time: Time (its existing contract, untouched);
  # reference_zone: is applied as a two-part post/pre-processing step around
  # that call:
  #   - before calling: if reference_time: is given, its utc_offset must
  #     agree with the zone's real offset at that instant, or omitted
  #     entirely, in which case the zone's current time anchors the call
  #     instead (both per the issue's acceptance criteria);
  #   - after calling: each result's `:naive` flag (see
  #     ext/duckling/src/lib.rs) tells us whether it's safe to reinterpret —
  #     only TimePoint::Naive (wall-clock) results may have their offset
  #     recomputed per their own resolved date; TimePoint::Instant results
  #     (relative arithmetic like "in 5 months") are left exactly as
  #     Native.parse returned them, since that arithmetic already happened
  #     inside the wrapped crate against a single FixedOffset before this gem
  #     ever saw it (issue #83's known, out-of-scope limitation).
  def self.parse(text, locale: "en", dims: ["time"], reference_time: nil, reference_zone: nil, with_latent: false, &block)
    if reference_time && !reference_time.is_a?(Time) && reference_time.respond_to?(:to_time)
      reference_time = reference_time.to_time
    end

    zone = nil
    if reference_zone
      zone = begin
        TZInfo::Timezone.get(reference_zone)
      rescue TZInfo::InvalidTimezoneIdentifier
        raise ArgumentError, "invalid reference_zone: #{reference_zone.inspect}"
      end
      if reference_time
        zone_offset = zone.period_for(reference_time).utc_total_offset
        if reference_time.utc_offset != zone_offset
          raise ArgumentError,
            "reference_time's utc_offset (#{reference_time.utc_offset}) does not match " \
            "reference_zone #{reference_zone.inspect}'s utc_offset (#{zone_offset}) at that instant"
        end
      else
        reference_time = zone.to_local(Time.now.utc)
      end
    end

    # reference_time: is only included when present: Native.parse's Magnus
    # binding treats an explicitly-passed `nil` for its Option<RubyTime>
    # kwarg differently from the key being absent entirely (the former raises
    # a TypeError trying to convert NilClass into Time) -- omitting the key
    # is what lets Rust's own None-based default (Context::default(), now
    # UTC) apply, same as when a caller never mentions reference_time: here.
    kwargs = {locale: locale, dims: dims, with_latent: with_latent}
    kwargs[:reference_time] = reference_time if reference_time

    results = if Fiber.scheduler
      Thread.new do
        Thread.current.report_on_exception = false
        Native.parse(text, **kwargs, &block)
      end.value
    else
      Native.parse(text, **kwargs, &block)
    end

    zone ? apply_reference_zone(results, zone) : results
  end

  # Walks every :time entity's resolved time point(s), reinterpreting each
  # TimePoint::Naive result's offset against `zone` for that result's own
  # date, in place. TimePoint::Instant results (`:naive` false) are left
  # untouched — see the reference_zone: note on .parse above.
  def self.apply_reference_zone(results, zone)
    results.each do |entity|
      value = entity[:value]
      next unless value

      case value[:type]
      when :value
        reinterpret_time_point!(value, zone)
        value[:values]&.each { |time_point| reinterpret_time_point!(time_point, zone) }
      when :interval
        reinterpret_time_point!(value[:from], zone)
        reinterpret_time_point!(value[:to], zone)
      end
    end
    results
  end
  private_class_method :apply_reference_zone

  def self.reinterpret_time_point!(time_point, zone)
    return unless time_point && time_point[:naive]

    t = time_point[:value]
    resolved = begin
      zone.local_time(t.year, t.month, t.day, t.hour, t.min, t.sec, t.usec)
    rescue TZInfo::PeriodNotFound, TZInfo::AmbiguousTime => e
      raise ArgumentError, "invalid or ambiguous naive time for reference zone: #{e.message}"
    end
    # Rebuild as a plain Time: TZInfo::Timezone#local_time returns a
    # TZInfo::TimeWithOffset (a Time subclass) -- every other code path in
    # this gem returns a plain Time, so leaving this one as a subclass would
    # be a real (if kind_of?-invisible) inconsistency for callers doing
    # anything stricter, like instance_of?(Time).
    time_point[:value] = Time.new(
      resolved.year, resolved.month, resolved.day,
      resolved.hour, resolved.min, resolved.sec + Rational(resolved.nsec, 1_000_000_000),
      resolved.utc_offset
    )
  end
  private_class_method :reinterpret_time_point!
end
