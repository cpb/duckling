# frozen_string_literal: true

# Empirical memory measurement for the duckling gem.
#
# Measures RSS/PSS/USS across the full lifecycle — bare Ruby, after
# `require "duckling"`, after each locale's first parse (showing how the
# Rust regex/rule cache grows per locale), and after 100 steady-state
# parses — with GC forced between each phase so deltas reflect committed
# memory, not transient garbage.
#
# The Rust `duckling` crate compiles grammar rules lazily per locale via
# `OnceLock` and intentionally leaks them via `Box::leak` — each locale's
# first parse is a permanent, one-time memory cost. This harness walks
# all 49 supported locales (27 have time rules; the rest still compile
# dependency-dimension rules) so the growth curve is visible.
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
  # All locales the gem accepts (ext/duckling/src/lib.rs lang_from_code).
  # 27 of these have time-dimension rules; the rest still compile
  # dependency-dimension rules (numeral, ordinal, duration, time-grain)
  # on first parse, so they contribute to memory growth too.
  LOCALES = %w[
    af ar bg bn ca cs da de el en es et fa fi fr ga he hi hr hu id is
    it ja ka km kn ko lo ml mn my nb ne nl pl pt ro ru sk sv sw ta te
    th tr uk vi zh
  ].freeze

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
    puts format("%-44s %s", label, parts.join("  "))

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
    puts "=" * 80

    base = snapshot("Baseline (bare Ruby)")

    require "duckling"
    after_req = snapshot("After require 'duckling'")

    GC.start
    after_req_gc = snapshot("After require + GC")

    # --- Per-locale first-parse growth -----------------------------------------

    puts ""
    puts "Per-locale first-parse growth (dims: [\"time\"]):"
    puts format("%-6s  %8s  %8s  %8s  %s",
      "locale", "RSS_KB", "dKB", "dMB", "entities")

    prev = after_req_gc
    locale_results = {}

    LOCALES.each do |loc|
      entities =
        begin
          Duckling.parse("tomorrow at 3pm", locale: loc, dims: ["time"]).size
        rescue => e
          "ERR:#{e.class}"
        end

      GC.start
      cur = rss_kb
      d_kb = cur - prev[:rss]
      puts format("%-6s  %8d  %+8d  %+7.1f  %s",
        loc, cur, d_kb, (d_kb / 1024.0), entities)
      locale_results[loc] = {rss: cur, entities: entities}
      prev = {rss: cur}
    end

    after_all_locales = snapshot("After all #{LOCALES.size} locales (1st parse each)")
    GC.start
    after_all_locales_gc = snapshot("After all locales + GC")

    # --- Steady state: 100 parses across locales -------------------------------

    # Cycle through locales that produced results (or all if none),
    # 100 total parses, to verify zero growth at steady state.
    locales_with_results = LOCALES.select { |l| locale_results[l][:entities].is_a?(Integer) }
    cycle = locales_with_results.any? ? locales_with_results : LOCALES

    100.times do |i|
      loc = cycle[i % cycle.size]
      Duckling.parse("next monday at noon", locale: loc, dims: ["time"])
    end

    GC.start
    after_100 = snapshot("After 100 steady-state parses + GC")

    # --- Summary ---------------------------------------------------------------

    puts ""
    puts "=== Deltas (post-GC steady state) ==="
    delta("require cost",     base,               after_req_gc)
    delta("all locales init", after_req_gc,       after_all_locales_gc)
    delta("100 steady parses", after_all_locales_gc, after_100)
    delta("TOTAL",            base,               after_100)

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
