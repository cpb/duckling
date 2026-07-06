# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in duckling.gemspec
gemspec

gem "dotenv"
gem "irb"
gem "rake"

gem "minitest"

# Test-only ground-truth oracle for asserting real IANA zone offsets in
# test/duckling_test.rb's reference_zone: "anchors at current time" case,
# since faking "now" via Ruby's Time.now has no effect on the Rust-side
# default clock (chrono::Utc::now(), read in ext/duckling/src/resolve.rs)
# that's actually used when reference_time: is omitted today.
gem "tzinfo"

gem "standard"
