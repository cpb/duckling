# Dockerfile for measuring duckling's runtime memory footprint on Linux.
#
# Mirrors Heroku's runtime: a slim Debian image with the precompiled
# platform gem installed (no compilation needed). The gem ships a .so per
# Ruby ABI (3.2/3.3/3.4/4.0); Ruby loads only the one matching its version.
#
# Usage:
#
#   docker build -t duckling-mem -f docs/spike/memory_footprint.Dockerfile .
#   docker run --rm duckling-mem
#
# To measure Ruby 3.4 instead, change the FROM line to ruby:3.4-slim.
# For 3.2, use ruby:3.2-slim.

FROM ruby:3.3-slim

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      procps \
    && rm -rf /var/lib/apt/lists/*

# Install the precompiled platform gem — no toolchain needed.
RUN gem install duckling --version 0.4.7 --platform x86_64-linux --no-document

COPY docs/spike/memory_footprint.rb /tmp/memory_footprint.rb

CMD ["ruby", "/tmp/memory_footprint.rb"]
