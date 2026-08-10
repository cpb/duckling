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
# so the bundle's tz data is env-driven and CI runs one environment per
# configuration (see docs/tz-database-axis.md):
#
#   unset      current tzinfo-data (the default environment)
#   "none"     omitted; tzinfo falls back to the host's zoneinfo files
#   "1.2022.7" that exact vintage
#
# Set BUNDLE_LOCKFILE alongside this for anything but the default, or the
# resolve overwrites the committed Gemfile.lock. An unrecognized value raises
# here rather than deep in the resolver.
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
