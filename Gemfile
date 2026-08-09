# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in duckling.gemspec
gemspec

gem "dotenv"
gem "irb"
gem "rake"

gem "minitest"

gem "standard"

# Loaded only when DUCKLING_COVERAGE=1 (test/support/coverage.rb), so it is
# `require: false` here — a plain `bundle exec rake` neither loads it nor pays
# for the counters.
gem "simplecov", require: false

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
# See test/skip_manifest.yml for what each leg is expected to cover.
#
# Set BUNDLE_LOCKFILE alongside this for anything but the default, or the leg's
# resolution overwrites the committed Gemfile.lock and leaves a dirty tree —
# which then blocks `rake release` and `rake benchmark:record_pr`, both guarded
# by release:guard_clean, with an error that looks unrelated.
#
# An unrecognized value is rejected here rather than passed through as a
# version requirement, which would fail deep in the resolver with a message
# about an unsatisfiable constraint instead of at the typo.
case (tzinfo_data = ENV["DUCKLING_TZINFO_DATA"].to_s)
when ""
  gem "tzinfo-data"
when "none"
  # tzinfo falls back to the host's zoneinfo files.
when /\A\d+(\.\d+)+\z/
  gem "tzinfo-data", tzinfo_data
else
  raise "DUCKLING_TZINFO_DATA=#{tzinfo_data.inspect} is not understood. " \
    "Use \"none\", an exact version such as \"1.2022.7\", or leave it unset."
end
