# frozen_string_literal: true

require "tzinfo"

module Duckling
  # Which tz database `reference_zone:` resolves against, for the
  # unknown-identifier error message. Behavioral because neither datasource
  # exposes a version. Internal, not public API. The suite's wider probes
  # live in test/support/tz_capabilities.rb. See docs/tz-database-axis.md.
  module TZInfoCapabilities
    module_function

    # DataSourceNotFound is a sibling of InvalidTimezoneIdentifier, not a
    # subclass, so it must be named. A probe is a total boolean: a host with
    # no database answers false.
    def backward_compat_links?
      TZInfo::Timezone.get("US/Eastern")
      true
    rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::DataSourceNotFound
      false
    end

    def identifier_count
      TZInfo::Timezone.all_identifiers.size
    rescue TZInfo::DataSourceNotFound
      0
    end

    # Zoneinfo is detected by capability (a caller may install a subclass),
    # the gem by class (loaded is not answered). Must not raise: it builds
    # failure messages.
    def datasource_description
      source = begin
        TZInfo::DataSource.get
      rescue TZInfo::DataSourceNotFound
        return "no tz datasource (no zoneinfo files, no tzinfo-data gem)"
      end

      return "system zoneinfo at #{source.zoneinfo_dir}" if source.respond_to?(:zoneinfo_dir)

      if defined?(TZInfo::DataSources::RubyDataSource) && source.is_a?(TZInfo::DataSources::RubyDataSource)
        version = " (tzdata #{TZInfo::Data::Version::TZDATA})" if defined?(TZInfo::Data::Version::TZDATA)
        return "the tzinfo-data gem#{version}"
      end

      "the #{source.class} tz datasource"
    end

    # The remedy is phrased as a condition, not a claim about the identifier:
    # only the database is checked. See docs/tz-database-axis.md.
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
