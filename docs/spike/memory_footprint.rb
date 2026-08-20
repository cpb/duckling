# frozen_string_literal: true

# Empirical memory measurement for the duckling gem.
#
# Measures RSS/PSS/USS at four points — bare Ruby, after `require "duckling"`,
# after the first `Duckling.parse`, and after 100 steady-state parses — with
# GC forced between each phase so deltas reflect committed memory, not
# transient garbage.
#
# On Linux it reads /proc/self/status and /proc/self/smaps_rollup for
# RSS/PSS/USS. On macOS it falls back to `ps -o rss` (RSS only; no PSS/USS).
#
# Usage:
#
#   # local (macOS)
#   ruby docs/spike/memory_footprint.rb
#
#   # Linux via Docker (matches Heroku's runtime)
#   docker build -t duckling-mem -f docs/spike/memory_footprint.Dockerfile .
#   docker run --rm duckling-mem
#
# The Dockerfile builds against ruby:3.3-slim by default; change the FROM
# line to ruby:3.4-slim (or 3.2) to measure a different ABI. The precompiled
# platform gem carries a .so for each, so no compilation is needed.

module MemoryFootprint
  module_function

  def rss_kb
    if RUBY_PLATFORM.include?("darwin")
      `ps -o rss= -p #{Process.pid}`.strip.to_i
    else
      File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
    end
  end

  def pss_kb
    return nil unless File.exist?("/proc/self/smaps_rollup")

    File.read("/proc/self/smaps_rollup")[/Pss:\s+(\d+)/, 1].to_i
  rescue StandardError
    nil
  end

  def uss_kb
    return nil unless File.exist?("/proc/self/smaps_rollup")

    rollup = File.read("/proc/self/smaps_rollup")
    clean = rollup[/Private_Clean:\s+(\d+)/, 1].to_i
    dirty = rollup[/Private_Dirty:\s+(\d+)/, 1].to_i
    clean + dirty
  rescue StandardError
    nil
  end

  def snapshot(label)
    rss = rss_kb
    pss = pss_kb
    uss = uss_kb

    parts = ["RSS=#{rss}KB (#{(rss / 1024.0).round(1)}MB)"]
    parts << "PSS=#{pss}KB (#{(pss / 1024.0).round(1)}MB)" if pss
    parts << "USS=#{uss}KB (#{(uss / 1024.0).round(1)}MB)" if uss
    puts format("%-28s %s", label, parts.join("  "))

    {rss: rss, pss: pss, uss: uss}
  end

  def delta(label, from, to)
    rss_delta = to[:rss] - from[:rss]
    pss_delta = (to[:pss] || 0) - (from[:pss] || 0)
    puts format("  %-20s +%dKB (%.1fMB)  PSS: +%dKB (%.1fMB)",
      label, rss_delta, (rss_delta / 1024.0), pss_delta, (pss_delta / 1024.0))
  end

  def run
    puts "Ruby #{RUBY_VERSION} on #{RUBY_PLATFORM}"
    puts "=" * 64

    base = snapshot("Baseline (bare Ruby)")

    require "duckling"
    after_req = snapshot("After require 'duckling'")

    GC.start
    after_req_gc = snapshot("After require + GC")

    Duckling.parse("tomorrow at 3pm", locale: "en", dims: ["time"])
    after_parse = snapshot("After 1st parse")

    GC.start
    after_parse_gc = snapshot("After 1st parse + GC")

    100.times { Duckling.parse("next monday at noon", locale: "en", dims: ["time"]) }
    GC.start
    after_100 = snapshot("After 100 parses + GC")

    puts ""
    puts "=== Deltas (post-GC steady state) ==="
    delta("require cost",  base,          after_req_gc)
    delta("parse init",    after_req_gc,  after_parse_gc)
    delta("100 parses",    after_parse_gc, after_100)
    delta("TOTAL",         base,          after_100)

    print_smaps_detail if File.exist?("/proc/self/smaps")
  end

  def print_smaps_detail
    puts ""
    puts "=== /proc/self/smaps: duckling.so segments ==="
    in_duckling = false
    total_rss = 0
    total_pss = 0
    File.readlines("/proc/self/smaps").each do |line|
      if line.include?("duckling")
        in_duckling = true
        next
      end

      next unless in_duckling

      if line =~ /^[0-9a-f]/
        in_duckling = false
        next
      end

      case line
      when /^Size:\s+(\d+)/
        print "  #{line.strip}  "
      when /^Rss:\s+(\d+)/
        total_rss += Regexp.last_match(1).to_i
        puts line.strip
      when /^Pss:\s+(\d+)/
        total_pss += Regexp.last_match(1).to_i
      end
    end
    puts ""
    puts "duckling.so total: RSS=#{total_rss}KB (#{(total_rss / 1024.0).round(1)}MB)" \
         "  PSS=#{total_pss}KB (#{(total_pss / 1024.0).round(1)}MB)"

    puts ""
    puts "=== /proc/self/smaps_rollup ==="
    puts File.read("/proc/self/smaps_rollup")
  end
end

MemoryFootprint.run
