# frozen_string_literal: true

require "tzinfo"

module Duckling
  # Describes *which* tz database `reference_zone:` is resolving against, so
  # an error about a zone can say where the answer came from.
  #
  # tzinfo picks its own source: `tzinfo-data` when that gem is installed,
  # otherwise the host's zoneinfo files. This gem does not depend on
  # `tzinfo-data`, so both are ordinary production configurations, and they do
  # not answer the same questions the same way — Debian and Ubuntu ship the
  # backward-compatibility links (`US/Eastern` and ~100 others) in a separate
  # `tzdata-legacy` package that is not installed by default, so an identifier
  # that resolves in development can be missing in production.
  #
  # Neither datasource exposes a version: `RubyDataSource` has no
  # `version_info`, and `ZoneinfoDataSource` offers only `zoneinfo_dir`. So
  # anything worth knowing has to be asked behaviorally — put a question to
  # the database rather than reading what release it claims to be.
  #
  # This module is deliberately limited to what `timezone_for`'s error message
  # needs. The suite discriminates the databases along more axes than this
  # (negative-DST modelling, tzdata vintage), and those probes live in
  # `test/support/tz_capabilities.rb`, which is where their only callers are —
  # `lib/` ships to every consumer and `test/` does not, so a probe with no
  # production caller does not belong here.
  #
  # Internal. Not part of the public API.
  #
  # Nothing is memoized. `TZInfo::DataSource.set` can swap the database
  # mid-process (the fixture-zone tests do exactly that), and a cached answer
  # would then describe a database that is no longer in use.
  module TZInfoCapabilities
    module_function

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

    # How many zone identifiers the database exposes. The single most legible
    # number for telling the two apart in an error message: `tzinfo-data`
    # publishes just under 600, a stock Ubuntu host just under 500, and the
    # difference is almost entirely the missing backward-compat links.
    def identifier_count
      TZInfo::Timezone.all_identifiers.size
    end

    # Human-readable name for the database in use, for error messages.
    #
    # Every branch has to be a question about the datasource that actually
    # answered. The zoneinfo case asks by capability (`respond_to?`), since a
    # caller may install their own subclass and the directory is the useful
    # part of the answer anyway. The gem case has to ask by class: whether
    # `tzinfo-data` is *loaded* says nothing about whether it *answered* — a
    # custom datasource in a bundle that also carries the gem would be
    # described as tzinfo-data, with an identifier count from the source that
    # really replied. A message whose whole job is to be trustworthy about
    # provenance cannot name the wrong database, so anything unrecognized
    # falls through to its own class name rather than to a guess.
    def datasource_description
      source = TZInfo::DataSource.get
      return "system zoneinfo at #{source.zoneinfo_dir}" if source.respond_to?(:zoneinfo_dir)

      if defined?(TZInfo::DataSources::RubyDataSource) && source.is_a?(TZInfo::DataSources::RubyDataSource)
        version = " (tzdata #{TZInfo::Data::Version::TZDATA})" if defined?(TZInfo::Data::Version::TZDATA)
        return "the tzinfo-data gem#{version}"
      end

      "the #{source.class} tz datasource"
    end

    # The parenthetical `timezone_for` appends to an unknown-identifier error.
    #
    # An unknown identifier is often a database difference rather than a typo
    # — `US/Eastern` is a perfectly good zone name that a stock Ubuntu host
    # does not have — so the message says which database answered and how many
    # names it knows.
    #
    # The remedy clause is phrased as a condition the reader evaluates, not as
    # a claim about the identifier they passed. Only the *database* is checked
    # here; whether this particular name is one of the ~100 in the `backward`
    # file is not knowable without shipping that list. Asserting it outright
    # would tell every genuine typo on a links-less host that `tzdata-legacy`
    # will supply it, which is the same mistake in the opposite direction —
    # and a list would be worse still, since a name it missed would get no
    # remedy at all.
    def unknown_identifier_diagnosis
      diagnosis = "resolved against #{datasource_description}, " \
        "which provides #{identifier_count} identifiers"
      return diagnosis if backward_compat_links?

      "#{diagnosis}; this database has no backward-compat names (US/Eastern and ~100 others), " \
        "so if that is what this is, it needs either the tzinfo-data gem or the " \
        "tzdata-legacy system package"
    end
  end
end
