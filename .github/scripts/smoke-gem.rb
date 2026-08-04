# frozen_string_literal: true

# Exercises an *installed* duckling gem the way a consumer does.
#
# The metadata checks in cross-gem.yml read a gem file. They never load it. A
# gem can hold a correctly named binary, for the right architecture, and still
# fail on the first call: rb-sys reads Ruby's internal object layout through
# the headers it compiles against, so a binary built against one Ruby ABI
# misreads objects from another, and magnus then rejects a genuine Time as not
# a Time. Only a real require and a real call find that.
#
# Run it against any Ruby, on any machine, after `gem install`. To rehearse a
# Heroku deploy, which has no Rust toolchain, run it in a plain Ruby container:
#
#   docker run --rm --platform linux/amd64 -v "$PWD:/w" -w /w ruby:3.3-slim \
#     bash -c 'gem install --no-document ./duckling-*-x86_64-linux.gem &&
#              ruby .github/scripts/smoke-gem.rb'
#
# EXPECTED_PLATFORM, when set, is the gem platform this run must have resolved.

gem "duckling"
require "duckling"

failures = []
spec = Gem::Specification.find_by_name("duckling")

expected_platform = ENV["EXPECTED_PLATFORM"]
if expected_platform && spec.platform.to_s != expected_platform
  failures << "resolved #{spec.platform} rather than #{expected_platform}; " \
    "RubyGems picked a different gem than this run meant to test"
end

binary = $LOADED_FEATURES.grep(/duckling\.(so|bundle)$/).first
if binary.nil?
  failures << "no compiled binary was loaded"
elsif !binary.start_with?(spec.gem_dir)
  # A stray build in the working directory would otherwise pass every check
  # below while the gem's own binary went untested.
  failures << "loaded #{binary}, which is outside the gem at #{spec.gem_dir}"
elsif spec.platform.to_s != "ruby"
  # A precompiled gem carries one binary per ABI. Loading the plain path means
  # the loader in lib/duckling.rb missed this Ruby's directory.
  abi = RUBY_VERSION[/\d+\.\d+/]
  unless binary.include?("/#{abi}/")
    failures << "loaded #{binary}, which is not this Ruby's #{abi} ABI directory"
  end
end

def check(failures, description)
  yield
rescue => e
  failures << "#{description}: #{e.class}: #{e.message}"
end

check(failures, "parse without reference_time") do
  entity = Duckling.parse("tomorrow at 3pm", dims: ["time"]).first
  raise "matched nothing" if entity.nil?
end

# The regression this script exists for. reference_time: is the only public
# entrypoint that converts a Ruby Time into a Rust type, so it is the call that
# an ABI mismatch breaks first.
check(failures, "parse with reference_time") do
  entity = Duckling.parse(
    "tomorrow at 3pm",
    dims: ["time"],
    reference_time: Time.new(2026, 8, 4, 9, 0, 0, "-04:00")
  ).first
  raise "matched nothing" if entity.nil?

  resolved = entity[:value][:Time][:Single][:value][:Naive][:value]
  raise "resolved a #{resolved.class}, not a Time" unless resolved.is_a?(Time)
  unless resolved.strftime("%Y-%m-%d %H:%M") == "2026-08-05 15:00"
    raise "resolved #{resolved}, expected 2026-08-05 15:00"
  end
end

# reference_zone: crosses back the other way, reading Time objects the native
# call produced.
check(failures, "parse with reference_zone") do
  entity = Duckling.parse(
    "tomorrow at 3pm",
    dims: ["time"],
    reference_time: Time.new(2026, 8, 4, 9, 0, 0, "-04:00"),
    reference_zone: "America/New_York"
  ).first
  raise "matched nothing" if entity.nil?
end

# A non-time dimension goes through serde_magnus rather than the hand-written
# Time patching, so it fails independently of the checks above.
check(failures, "parse a non-time dimension") do
  entity = Duckling.parse("42 dollars", dims: ["amount-of-money"]).first
  raise "matched nothing" if entity.nil?

  amount = entity[:value][:AmountOfMoney][:Value][:value]
  raise "read #{amount.inspect}, expected 42" unless (amount - 42.0).abs < Float::EPSILON
end

if failures.any?
  abort("Smoke test failed on Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}):\n- #{failures.join("\n- ")}")
end

puts "#{spec.full_name} works on Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM})"
puts "  binary: #{binary}"
