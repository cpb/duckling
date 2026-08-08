# frozen_string_literal: true

require "tzinfo"

module Duckling
  # Behavioral probes describing *which* tz database `reference_zone:` is
  # resolving against.
  #
  # tzinfo picks its own source: `tzinfo-data` when that gem is installed,
  # otherwise the host's zoneinfo files. This gem does not depend on
  # `tzinfo-data`, so both are ordinary production configurations, and they do
  # not answer the same questions the same way. Two drift axes, independent of
  # each other:
  #
  # - **Modelling.** Debian and Ubuntu compile tzdata in *rearguard* format,
  #   which strips negative DST: Europe/Dublin is a negative-DST zone under
  #   `tzinfo-data` and an ordinary positive-DST zone under the host's files.
  #   Those distributions also moved the backward-compatibility links
  #   (`US/Eastern` and friends) into a separate `tzdata-legacy` package that
  #   is not installed by default, so ~100 identifiers simply do not exist.
  # - **Vintage.** A pinned `tzinfo-data` or an unpatched host can predate a
  #   rule change — Greenland's 2023a rules, say — and answer with the old
  #   rules rather than raising.
  #
  # Neither datasource exposes a version: `RubyDataSource` has no
  # `version_info`, and `ZoneinfoDataSource` offers only `zoneinfo_dir`. So
  # discrimination has to be behavioral — ask the database a question whose
  # answer differs, not what release it claims to be.
  #
  # Not part of the public API. It exists so two callers can stop guessing:
  # `timezone_for`'s error message, which names the database that failed to
  # find an identifier, and the test suite, which turns a genuinely-absent
  # capability into a named skip instead of a mystery failure.
  #
  # Nothing here is memoized. `TZInfo::DataSource.set` can swap the database
  # mid-process (the fixture-zone tests do exactly that), and a cached answer
  # would then describe a database that is no longer in use.
  module TZInfoCapabilities
    # Probe name (as `stale_tolerant` and the skip manifest spell it) => the
    # predicate that answers it. Going through this map rather than calling
    # the predicates directly makes a typo'd capability name a hard error at
    # the call site instead of a silently-false answer.
    CAPABILITIES = {
      negative_dst: :models_negative_dst?,
      backward_compat_links: :backward_compat_links?,
      greenland_2023_rules: :greenland_2023_rules?
    }.freeze

    module_function

    # Does this database model negative DST?
    #
    # Europe/Dublin is the canonical case: IANA models it as +01:00 standard
    # year-round with a *negative* one-hour saving in winter, so tzinfo reports
    # January — GMT — as the `dst?` period. Rearguard-format data re-expresses
    # the same offsets as ordinary positive DST, making January plainly
    # standard time.
    #
    # This is what decides whether `local_time_in_zone`'s
    # first-occurrence-by-position rule is distinguishable from a `dst?`-flag
    # lookup at all. Under rearguard data the two agree everywhere, and a test
    # written against Dublin quietly stops testing anything.
    def models_negative_dst?
      TZInfo::Timezone.get("Europe/Dublin").period_for(Time.utc(2026, 1, 15)).dst?
    rescue TZInfo::InvalidTimezoneIdentifier
      false
    end

    # Does this database carry the backward-compatibility links?
    #
    # `US/Eastern` is a link to `America/New_York` in IANA's `backward` file.
    # `tzinfo-data` bundles it; Debian and Ubuntu ship it in `tzdata-legacy`,
    # which is not installed by default.
    def backward_compat_links?
      TZInfo::Timezone.get("US/Eastern")
      true
    rescue TZInfo::InvalidTimezoneIdentifier
      false
    end

    # Does this database carry Greenland's post-2023a rules?
    #
    # America/Nuuk springs forward at 23:00 local under those rules, so
    # 2026-03-28 23:30 is a wall clock the zone never observes. Older vintages
    # answer two different ways, and both matter: before 2020a the identifier
    # does not exist at all (it was `America/Godthab`), and 2021–2022 vintages
    # know the name but still place Greenland at -03:00/-02:00 with no gap
    # anywhere near that wall clock — the zone resolves fine and gives a
    # different answer, which is the harder failure to attribute.
    def greenland_2023_rules?
      TZInfo::Timezone.get("America/Nuuk")
        .periods_for_local(Time.utc(2026, 3, 28, 23, 30))
        .empty?
    rescue TZInfo::InvalidTimezoneIdentifier
      false
    end

    # True when this database can answer `capability`. Raises on a name that
    # isn't in CAPABILITIES rather than reporting it absent.
    def supports?(capability)
      predicate = CAPABILITIES.fetch(capability.to_sym) do
        raise ArgumentError,
          "unknown tz capability #{capability.inspect}, expected one of #{CAPABILITIES.keys.inspect}"
      end
      public_send(predicate)
    end

    # How many zone identifiers the database exposes. The single most legible
    # number for telling the two apart in an error message: `tzinfo-data`
    # publishes just under 600, a stock Ubuntu host just under 500, and the
    # difference is almost entirely the missing backward-compat links.
    def identifier_count
      TZInfo::Timezone.all_identifiers.size
    end

    # Human-readable name for the database in use, for error messages.
    #
    # Detected by capability (`respond_to?(:zoneinfo_dir)`) rather than by
    # class: a caller is free to install their own `TZInfo::DataSource`
    # subclass, and the directory is the useful part of the answer anyway.
    def datasource_description
      source = TZInfo::DataSource.get
      return "system zoneinfo at #{source.zoneinfo_dir}" if source.respond_to?(:zoneinfo_dir)
      return "the tzinfo-data gem (tzdata #{TZInfo::Data::Version::TZDATA})" if defined?(TZInfo::Data::Version::TZDATA)

      "the #{source.class} tz datasource"
    end

    # The parenthetical `timezone_for` appends to an unknown-identifier error.
    #
    # An unknown identifier is far more often a database difference than a
    # typo — `US/Eastern` is a perfectly good zone name that a stock Ubuntu
    # host does not have — so the message says which database answered, how
    # many names it knows, and, when the backward-compat links are the likely
    # explanation, both ways to get them back.
    def unknown_identifier_diagnosis
      diagnosis = "resolved against #{datasource_description}, " \
        "which provides #{identifier_count} identifiers"
      return diagnosis if backward_compat_links?

      "#{diagnosis}; backward-compat names such as this one need either the " \
        "tzinfo-data gem or the tzdata-legacy system package"
    end
  end
end
