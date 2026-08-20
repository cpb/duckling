# Dockerfile for measuring duckling's runtime memory footprint on Linux.
#
# Mirrors Heroku's runtime: a slim Debian image with the precompiled
# platform gem installed (no compilation needed). The gem ships a .so per
# Ruby ABI (3.2/3.3/3.4/4.0); Ruby loads only the one matching its version.
#
# Also includes the Ruby Regexp comparison probe, which extracts the
# duckling crate's ~3,400 regex patterns and compiles them as Ruby
# Regexp objects to compare memory cost against the Rust regex crate.
#
# Usage:
#
#   # duckling runtime footprint (all 49 locales)
#   docker build -t duckling-mem -f docs/spike/memory_footprint.Dockerfile .
#   docker run --rm duckling-mem
#
#   # Ruby Regexp comparison (no duckling gem needed)
#   docker run --rm duckling-mem ruby /tmp/ruby_regexp_comparison.rb
#
# To measure Ruby 3.4 instead, change the FROM line to ruby:3.4-slim.
# For 3.2, use ruby:3.2-slim.

FROM ruby:3.3-slim

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      procps \
    && rm -rf /var/lib/apt/lists/*

# Install the precompiled platform gem — no toolchain needed.
RUN gem install duckling --version 0.4.7 --platform x86_64-linux --no-document

# Pattern cache for the comparison probe (extracted from the duckling
# Rust crate source at docs/spike/duckling_patterns.json).
COPY docs/spike/memory_footprint.rb              /tmp/memory_footprint.rb
COPY docs/spike/ruby_regexp_comparison.rb        /tmp/ruby_regexp_comparison.rb
COPY docs/spike/duckling_patterns.json           /tmp/duckling_patterns.json

CMD ["ruby", "/tmp/memory_footprint.rb"]
