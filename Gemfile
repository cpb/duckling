# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in duckling.gemspec
gemspec

gem "dotenv"
gem "irb"
gem "rake"

gem "minitest"

gem "standard"

# tzinfo-data is deliberately not a runtime dependency (see duckling.gemspec),
# so which tz database resolves a zone is a property of the consumer's
# environment — and the two databases disagree, both about modelling
# (negative DST, backward-compat links) and about vintage. That makes "which
# database" a test axis rather than a constant, so the bundle's tz data is
# env-driven and CI runs one leg per configuration:
#
#   unset      current tzinfo-data — the default leg, and what a consumer who
#              opts into the gem gets
#   "none"     omitted, so tzinfo falls back to the host's zoneinfo files —
#              what a consumer who does nothing now gets
#   "1.2022.7" that exact vintage, reproducing a stale-but-present database
#
# See test/tz_skip_manifest.yml for what each leg is expected to cover.
tzinfo_data = ENV["DUCKLING_TZINFO_DATA"].to_s
if tzinfo_data.empty?
  gem "tzinfo-data"
elsif tzinfo_data != "none"
  gem "tzinfo-data", tzinfo_data
end
