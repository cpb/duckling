# frozen_string_literal: true

require "tzinfo"

# Behavioral tz-database probes used only by the suite: the gate behind
# test/capabilities/ and the assertions in test/environments/. Probes with a
# production caller live in Duckling::TZInfoCapabilities. Rules for every
# probe: answer false on a host with no database (DataSourceNotFound does
# not inherit from InvalidTimezoneIdentifier), and memoize nothing
# (DataSource.set swaps the database mid-process). See docs/tz-database-axis.md.
module TZCapabilities
  # Capability name (as test/capabilities/ filenames spell it) => predicate.
  CAPABILITIES = {
    negative_dst: :models_negative_dst?,
    backward_compat_links: :backward_compat_links?,
    greenland_2023_rules: :greenland_2023_rules?
  }.freeze

  module_function

  # Europe/Dublin: IANA models winter GMT as the dst? period (negative DST);
  # rearguard data re-expresses the same offsets as positive DST.
  def models_negative_dst?
    TZInfo::Timezone.get("Europe/Dublin").period_for(Time.utc(2026, 1, 15)).dst?
  rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::DataSourceNotFound
    false
  end

  # America/Nuuk skips 2026-03-28 23:30 under the 2023a rules; older vintages
  # resolve the zone and answer with the old rules.
  def greenland_2023_rules?
    TZInfo::Timezone.get("America/Nuuk")
      .periods_for_local(Time.utc(2026, 3, 28, 23, 30))
      .empty?
  rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::DataSourceNotFound
    false
  end

  def backward_compat_links?
    Duckling::TZInfoCapabilities.backward_compat_links?
  end

  def datasource_description
    Duckling::TZInfoCapabilities.datasource_description
  end

  # Raises on an unknown capability name.
  def supports?(capability)
    predicate = CAPABILITIES.fetch(capability.to_sym) do
      raise ArgumentError,
        "unknown tz capability #{capability.inspect}, expected one of #{CAPABILITIES.keys.inspect}"
    end
    public_send(predicate)
  end
end
