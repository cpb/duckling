# frozen_string_literal: true

require "tzinfo"

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
  # reference_zone: never crosses into Native.parse — the wrapped Rust crate
  # has no IANA-zone concept at all, only the single FixedOffset it derives
  # from reference_time:. Per-date-correct offsets therefore have to come from
  # a real tz database on the Ruby side, so reference_zone: is applied as a
  # two-part step around the native call: validate the zone (and reference_time:'s
  # agreement with it) before, then reinterpret Naive results after.
  #
  # A fixed offset and a zone that disagree at the reference instant have no
  # principled resolution — silently preferring either would resolve results
  # against an offset the caller never asked for — so that combination raises
  # rather than guessing.
  def self.parse(text, locale: "en", dims: ["time"], reference_time: nil, with_latent: false, reference_zone: nil)
    reference_time = reference_time.to_time if reference_time && !reference_time.is_a?(Time) && reference_time.respond_to?(:to_time)

    if reference_zone
      zone = timezone_for(reference_zone)
      verify_reference_time_offset!(reference_time, zone, reference_zone) if reference_time
    end

    kwargs = {locale: locale, dims: dims, with_latent: with_latent}
    kwargs[:reference_time] = reference_time if reference_time

    entities = if Fiber.scheduler
      Thread.new do
        Thread.current.report_on_exception = false
        Native.parse(text, **kwargs)
      end.value
    else
      Native.parse(text, **kwargs)
    end

    apply_reference_zone(entities, reference_zone)
  end

  # Reinterprets every TimePoint::Naive (wall-clock) leaf of each :time entity
  # against `reference_zone`, using the real IANA offset for that leaf's own
  # date rather than the single fixed offset reference_time: carries.
  #
  # TimePoint::Instant leaves are left strictly alone: the wrapped crate
  # already collapsed their relative arithmetic against one FixedOffset before
  # this gem ever saw the result, so there is no wall-clock left to reinterpret.
  # That arithmetic's DST imprecision is known and out of scope (issue #83).
  #
  # Walks the externally-tagged shape ext/duckling/src/lib.rs's patch_time_value
  # produces, and raises on any tag it doesn't recognize: a shape drift on the
  # Rust side must fail loudly here rather than quietly returning results
  # resolved against the wrong offset.
  def self.apply_reference_zone(entities, reference_zone)
    return entities unless reference_zone

    zone = timezone_for(reference_zone)
    entities.each do |entity|
      next unless entity[:dim] == :time
      reinterpret_time_value!(entity[:value][:Time], zone)
    end
    entities
  end

  def self.reinterpret_time_value!(value, zone)
    if (single = value && value[:Single])
      reinterpret_time_point!(single[:value], zone)
      single[:values]&.each { |point| reinterpret_time_point!(point, zone) }
    elsif (interval = value && value[:Interval])
      reinterpret_interval_endpoints!(interval, zone)
      interval[:values]&.each { |endpoints| reinterpret_interval_endpoints!(endpoints, zone) }
    else
      raise "unrecognized :time value shape, expected a :Single or :Interval tag: #{value.inspect}"
    end
  end
  private_class_method :reinterpret_time_value!

  # An Interval's from/to are Option<TimePoint> on the Rust side, and serde
  # emits Option::None as a present key holding nil — hence the nil tolerance
  # in reinterpret_time_point!, rather than a missing-key check here.
  def self.reinterpret_interval_endpoints!(endpoints, zone)
    reinterpret_time_point!(endpoints[:from], zone)
    reinterpret_time_point!(endpoints[:to], zone)
  end
  private_class_method :reinterpret_interval_endpoints!

  def self.reinterpret_time_point!(point, zone)
    return if point.nil?

    if (naive = point[:Naive])
      naive[:value] = local_time_in_zone(zone, naive[:value])
    elsif !point.key?(:Instant)
      raise "unrecognized TimePoint shape, expected a :Naive or :Instant tag: #{point.inspect}"
    end
  end
  private_class_method :reinterpret_time_point!

  # The Rust side already resolved this Naive wall-clock against reference_time:'s
  # fixed offset, so the Time's own calendar fields still read as that intended
  # wall-clock — re-anchoring those same fields in `zone` is what picks up the
  # per-date DST offset.
  #
  # A wall-clock that a spring-forward gap skipped, or that a fall-back overlap
  # made ambiguous, has no single correct offset; surface that as an ArgumentError
  # about the caller's input rather than leaking a TZInfo internal.
  def self.local_time_in_zone(zone, time)
    zone.local_time(time.year, time.month, time.day, time.hour, time.min, time.sec, time.subsec)
  rescue TZInfo::PeriodNotFound
    raise ArgumentError,
      "#{time.strftime("%Y-%m-%d %H:%M:%S")} does not exist in #{zone.identifier} " \
      "(skipped by a daylight-saving spring-forward transition)"
  rescue TZInfo::AmbiguousTime
    raise ArgumentError,
      "#{time.strftime("%Y-%m-%d %H:%M:%S")} is ambiguous in #{zone.identifier} " \
      "(it occurs twice around a daylight-saving fall-back transition)"
  end
  private_class_method :local_time_in_zone

  def self.timezone_for(reference_zone)
    TZInfo::Timezone.get(reference_zone)
  rescue TZInfo::InvalidTimezoneIdentifier
    raise ArgumentError, "invalid reference_zone: #{reference_zone.inspect}"
  end
  private_class_method :timezone_for

  def self.verify_reference_time_offset!(reference_time, zone, reference_zone)
    zone_offset = zone.period_for(reference_time).observed_utc_offset
    return if reference_time.utc_offset == zone_offset

    raise ArgumentError,
      "reference_time's utc_offset (#{reference_time.utc_offset}) does not match " \
      "reference_zone #{reference_zone.inspect}'s utc_offset (#{zone_offset}) at that instant"
  end
  private_class_method :verify_reference_time_offset!
end
