# frozen_string_literal: true

require "tzinfo"

require_relative "duckling/version"
require_relative "duckling/duckling"

module Duckling
  # Raised when the serialized :time :value shape drifts from the typed walk in
  # ext/duckling/src/lib.rs's patch_time_value/patch_time_point — a wrapper bug.
  # Deliberately a RuntimeError subclass (not ArgumentError) so a caller
  # rescuing ArgumentError around bad locale:/reference_zone: input can't
  # swallow it, and a *named* one (not bare RuntimeError) so it's greppable and
  # can't be satisfied by the unrelated native-panic RuntimeError. Mirrors the
  # internal_error() class in lib.rs.
  class ShapeError < RuntimeError; end

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
  #
  # reference_zone: only reinterprets result offsets after the fact; it does
  # NOT anchor the parse. Given without reference_time:, relative expressions
  # ("tomorrow") still anchor on the machine-local clock, not on "now" in that
  # zone, so on a US host reference_zone: "Asia/Tokyo" can land on the wrong
  # calendar day. Pass a reference_time: in the zone to anchor as well.
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

    zone ? reinterpret_entities!(entities, zone) : entities
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

    reinterpret_entities!(entities, timezone_for(reference_zone))
  end

  # Zone-object core of apply_reference_zone. parse calls this directly with
  # the TZInfo::Timezone it already resolved for offset validation, so the
  # zone is looked up once per call rather than once for validation and again
  # for reinterpretation.
  def self.reinterpret_entities!(entities, zone)
    entities.each do |entity|
      next unless entity[:dim] == :time
      reinterpret_time_value!(entity[:value][:Time], zone)
    end
    entities
  end
  private_class_method :reinterpret_entities!

  # Walks the Single/Interval + Naive/Instant tagged shape. A primary value
  # (single[:value], or an interval's from/to) and every `values` recurrence
  # entry are resolved identically — see local_time_in_zone.
  def self.reinterpret_time_value!(value, zone)
    if (single = value && value[:Single])
      reinterpret_time_point!(single[:value], zone)
      single[:values]&.each { |point| reinterpret_time_point!(point, zone) }
    elsif (interval = value && value[:Interval])
      reinterpret_interval_endpoints!(interval, zone)
      interval[:values]&.each { |endpoints| reinterpret_interval_endpoints!(endpoints, zone) }
    else
      raise ShapeError, "unrecognized :time value shape, expected a :Single or :Interval tag: #{value.inspect}"
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
      raise ShapeError, "unrecognized TimePoint shape, expected a :Naive or :Instant tag: #{point.inspect}"
    end
  end
  private_class_method :reinterpret_time_point!

  # The Rust side already resolved this Naive wall-clock against reference_time:'s
  # fixed offset, so the Time's own calendar fields still read as that intended
  # wall-clock — re-anchoring those same fields in `zone` is what picks up the
  # per-date DST offset.
  #
  # A wall-clock that a spring-forward gap skipped, or that a fall-back overlap
  # made ambiguous, has no single correct offset — but there's no benefit to
  # raising over it either, whether the value is a primary one the caller
  # literally named or a generated recurrence entry: both get the same
  # deterministic resolution — a gap shifts the wall clock forward by the
  # transition's delta (02:30 on a US spring-forward day becomes 03:30 EDT),
  # an overlap takes the first (pre-transition) occurrence.
  #
  # The first occurrence is selected via the block form (periods_for_local
  # yields periods in chronological order), NOT tzinfo's dst flag: dst=true
  # only means "first" where the pre-transition period observes DST, and
  # negative-DST zones invert that — Europe/Dublin models winter GMT as its
  # dst?==true period, so dst=true there would pick the second occurrence, an
  # hour off as an instant. (ActiveSupport::TimeZone#local has exactly that
  # Dublin behavior, via period_for_local's dst=true default — a deliberate
  # departure here, like the Lord Howe one on gap_delta.) The explicit nil dst
  # argument keeps a global Timezone.default_dst setting from pre-filtering
  # the periods before the block sees them.
  #
  # Preserving the gap's original wall clock and merely stamping the
  # post-transition offset on it would produce a Time whose offset the zone
  # does not observe at that instant — 02:30 -04:00 is 06:30Z, and at 06:30Z
  # New York is still on EST — so it would read back as 01:30 EST, an hour
  # before the occurrence it stands for and on the wrong side of the
  # transition. Shifting forward keeps the instant and its rendered local
  # time in agreement.
  def self.local_time_in_zone(zone, time)
    first_occurrence = lambda do |t|
      zone.local_time(t.year, t.month, t.day, t.hour, t.min, t.sec, t.subsec, nil) do |periods|
        periods.first
      end
    end
    first_occurrence.call(time)
  rescue TZInfo::PeriodNotFound
    first_occurrence.call(time + gap_delta(zone, time))
  end
  private_class_method :local_time_in_zone

  # How wide the spring-forward gap `time` fell into is — i.e. how far forward
  # a skipped wall clock must move to land on a real one. DST transitions are
  # months apart, so the single offset-increasing transition within a day of
  # `time` is necessarily the one whose gap it landed in.
  #
  # The ±1-day scan window is centered on the skipped wall clock itself read
  # as UTC — not on the UTC midnight of its date. The transition's UTC instant
  # is the wall clock minus a zone offset, and offsets never reach a day, so
  # this window always contains it; a midnight-anchored window does not. A
  # gap late in the local day in a negative-offset zone (America/Nuuk springs
  # forward at 23:00 local) has its transition instant past the *next* UTC
  # midnight, outside a midnight-anchored window — `find` returned nil and
  # this method crashed instead of resolving.
  #
  # Read from the transition rather than assumed to be 3600. ActiveSupport's
  # TimeWithZone#get_period_and_ensure_valid_local_time instead hardcodes
  # `@time += 1.hour` and retries: for Australia/Lord_Howe's 30-minute gap
  # that lands half an hour past the gap's end (02:15 → 03:15 rather than
  # 02:45). Every one-hour gap — i.e. every zone in current use but Lord Howe
  # — resolves identically either way.
  def self.gap_delta(zone, time)
    wall_clock = Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec)
    transition = zone.transitions_up_to(wall_clock + 86400, wall_clock - 86400)
      .find { |t| t.offset.observed_utc_offset > t.previous_offset.observed_utc_offset }
    transition.offset.observed_utc_offset - transition.previous_offset.observed_utc_offset
  end
  private_class_method :gap_delta

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
