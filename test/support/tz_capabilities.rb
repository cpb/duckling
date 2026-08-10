# frozen_string_literal: true

require "tzinfo"

# Behavioral probes the *suite* uses to decide whether a tz database can
# answer a question at all — the gate behind test/capabilities/ (a file
# loads only where its probe passes) and the assertions in
# test/environments/ contracts.
#
# Separate from `Duckling::TZInfoCapabilities` by consumer, not by topic. That
# module ships in `lib/` and is limited to what `timezone_for`'s error message
# needs; these probes have no production caller, and `lib/` reaches every
# consumer of the gem while `test/` reaches none. `backward_compat_links?` is
# needed on both sides, so production owns it and this delegates.
#
# The probes exist because neither datasource exposes a version — discrimination
# has to be a question the database answers, not a release string. They cover
# the two drift axes the suite cares about:
#
# - **Modelling.** Some distributions compile tzdata in rearguard format, which
#   strips negative DST; others ship vanguard. "Host zoneinfo" does not settle
#   it, and the split is not the one you would guess — Ubuntu 24.04 is
#   rearguard while Debian trixie is vanguard, both verified from this suite's
#   own banner line. Distributions in that family also move the
#   backward-compat links to a `tzdata-legacy` package that is not installed
#   by default, which is a third, independent property.
# - **Vintage.** A pinned `tzinfo-data` or an unpatched host can predate a rule
#   change and answer with the old rules rather than raising.
# - **Absence.** A host may have no tz database at all (scratch, distroless).
#   Every probe answers `false` there rather than raising: callers — the
#   capability loader in test_helper.rb, and every assertion in
#   test/environments/ — treat a probe as a total boolean, so absence has to be
#   a value, not an exception. `TZInfo::DataSourceNotFound` is a *sibling* of
#   `InvalidTimezoneIdentifier`, not a subclass, so it must be named
#   explicitly; omitting it made the whole suite fail to load on that host.
#
# Nothing is memoized: `TZInfo::DataSource.set` swaps the database mid-process
# in the fixture-zone tests, and a cached answer would describe the wrong one.
module TZCapabilities
  # Probe name (as test/capabilities/ filenames spell it) => the predicate
  # that answers it. Going through this map rather than calling the
  # predicates directly makes a typo'd capability name a hard error at the call
  # site instead of a silently-false answer.
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
  # the same offsets as ordinary positive DST, making January plainly standard
  # time.
  #
  # This is what decides whether `local_time_in_zone`'s
  # first-occurrence-by-position rule is distinguishable from a `dst?`-flag
  # lookup at all. Under rearguard data the two agree everywhere, and a test
  # written against Dublin quietly stops testing anything — which is why the
  # Dublin test asserts this same predicate as its own premise rather than
  # restating the zone and date, so there is one definition of the condition
  # and the test/capabilities/ loader consults exactly it.
  def models_negative_dst?
    TZInfo::Timezone.get("Europe/Dublin").period_for(Time.utc(2026, 1, 15)).dst?
  rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::DataSourceNotFound
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
  rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::DataSourceNotFound
    false
  end

  # Production owns this one — the unknown-identifier error message needs it.
  def backward_compat_links?
    Duckling::TZInfoCapabilities.backward_compat_links?
  end

  def datasource_description
    Duckling::TZInfoCapabilities.datasource_description
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
end
