# frozen_string_literal: true

# Comparison probe: what would the memory cost be if the duckling gem's
# ~3,400 regex patterns were compiled as Ruby Regexp objects instead of
# by the Rust regex crate?
#
# The Rust `regex` crate compiles each pattern into a hybrid DFA/NFA
# automaton — the DFA states are pre-computed for O(n) matching, but the
# compiled representation is large (~136 KB average per pattern across
# all locales, 536 MB total for all 49 locales).
#
# Ruby's `Regexp` (Onigmo) compiles patterns to bytecode that is
# interpreted at match time — the compiled representation is much
# smaller, but matching is O(nm) worst case.
#
# This probe extracts all unique regex patterns from the duckling Rust
# crate source, compiles them as Ruby Regexp objects (keeping them alive,
# mirroring the Rust side's `Box::leak`), and measures the memory cost.
# It also runs 100 matches per pattern against a sample string to show
# steady-state memory and measure matching speed.
#
# Usage:
#
#   ruby docs/spike/ruby_regexp_comparison.rb
#
# The pattern extraction requires the duckling crate source in the cargo
# registry cache. If not present, the probe falls back to loading patterns
# from a JSON file if one was previously generated.

require "json"

module RubyRegexpComparison
  DUCKLING_SRC = File.expand_path(
    "~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/duckling-0.4.0/src"
  )
  # When running locally, try the cargo cache first, then the committed
  # pattern file in docs/spike/. In Docker the file is copied to /tmp/.
  PATTERN_CACHES = [
    "/tmp/duckling_patterns.json",
    File.expand_path("duckling_patterns.json", __dir__),
  ].freeze

  # The sample text used for matching speed comparison.
  SAMPLE_TEXT = "I need to schedule a meeting tomorrow at 3pm for 2 hours"

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

  def snapshot(label)
    rss = rss_kb
    pss = pss_kb
    parts = ["RSS=#{rss}KB (#{(rss / 1024.0).round(1)}MB)"]
    parts << "PSS=#{pss}KB (#{(pss / 1024.0).round(1)}MB)" if pss
    puts format("%-48s %s", label, parts.join("  "))
    {rss: rss, pss: pss}
  end

  def delta(label, from, to)
    rss_d = to[:rss] - from[:rss]
    pss_d = (to[:pss] || 0) - (from[:pss] || 0)
    puts format("  %-24s %+dKB (%+.1fMB)  PSS: %+dKB (%+.1fMB)",
      label, rss_d, (rss_d / 1024.0), pss_d, (pss_d / 1024.0))
  end

  def extract_patterns
    patterns = []
    Dir.glob("#{DUCKLING_SRC}/**/*.rs").sort.each do |file|
      source = File.read(file)
      # Match regex(r"...") and regex("...") including multi-line
      source.scan(/regex\(\s*(?:(r)"([^"]*)"|()"((?:\\.|[^"\\])*)")\s*\)?/m) do |m|
        raw, raw_pat, _, cooked_pat = m
        if raw == "r"
          patterns << raw_pat
        else
          # Unescape Rust cooked string literals
          pat = cooked_pat.gsub(/\\(.)/) do
            case $1
            when "n" then "\n"
            when "t" then "\t"
            when "\\" then "\\"
            when "\"" then "\""
            when "'" then "'"
            when "0" then "\0"
            else $&
            end
          end
          patterns << pat
        end
      end
    end
    patterns.uniq
  end

  def load_patterns
    patterns = if Dir.exist?(DUCKLING_SRC)
      extract_patterns
    elsif (cache = PATTERN_CACHES.find { |f| File.exist?(f) })
      JSON.parse(File.read(cache))
    else
      raise "Cannot find duckling crate source at #{DUCKLING_SRC} or pattern cache in #{PATTERN_CACHES}"
    end

    puts "Loaded #{patterns.size} unique regex patterns from duckling crate"
    lengths = patterns.map(&:bytesize)
    puts "  Source bytes: #{lengths.sum} (#{(lengths.sum / 1024.0).round(1)}KB)"
    puts "  Mean length: #{(lengths.sum / lengths.size.to_f).round(1)} bytes"
    puts "  Max length: #{lengths.max} bytes"
    patterns
  end

  def run
    puts "Ruby #{RUBY_VERSION} on #{RUBY_PLATFORM}"
    puts "Regex engine: #{RUBY_DESCRIPTION[/ruby 3\.\d+.*?\[/] || RUBY_DESCRIPTION[0..40]}"
    puts "=" * 80

    patterns = load_patterns

    base = snapshot("Baseline (bare Ruby, patterns loaded as strings)")

    # --- Compile all patterns as Regexp objects, keeping them alive ---------

    # Pre-allocate the array so it doesn't reallocate incrementally
    compiled = Array.new(patterns.size)
    compile_errors = 0

    patterns.each_with_index do |pat, i|
      begin
        compiled[i] = Regexp.new(pat)
      rescue => e
        compile_errors += 1
        compiled[i] = nil
      end
    end

    # Pin the compiled array so it's never GC'd (mirrors Box::leak)
    @pinned = compiled.freeze

    GC.start
    after_compile = snapshot("After compiling #{compiled.compact.size} Regexp objects")

    # Measure per-batch growth to see the curve
    puts ""
    puts "Per-batch compile growth (500 patterns at a time):"

    # Redo with incremental measurement for the curve
    @pinned = nil # unpick the first array
    compiled2 = Array.new(patterns.size)
    batch_size = 500
    prev_rss = base[:rss]

    (patterns.size / batch_size + 1).times do |batch|
      start_idx = batch * batch_size
      end_idx = [start_idx + batch_size, patterns.size].min
      break if start_idx >= patterns.size

      start_idx.upto(end_idx - 1) do |i|
        compiled2[i] = Regexp.new(patterns[i]) rescue nil
      end

      GC.start
      cur = rss_kb
      d = cur - prev_rss
      puts format("  patterns %4d-%4d: RSS=%6dKB  delta=%+5dKB (%+.1fMB)",
        start_idx, end_idx - 1, cur, d, (d / 1024.0))
      prev_rss = cur
    end

    # Keep this one alive instead
    @pinned = compiled2.freeze
    compiled = nil # let the first array go

    GC.start
    after_curve = snapshot("After incremental compile (all #{patterns.size})")

    # --- Match speed comparison ---------------------------------------------

    puts ""
    puts "Match speed: 100 matches per pattern against sample text"
    puts "  Sample: \"#{SAMPLE_TEXT}\""

    match_count = 0
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times do
      @pinned.each do |re|
        next unless re

        re.match?(SAMPLE_TEXT)
        match_count += 1
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    GC.start
    after_match = snapshot("After #{match_count} matches + GC")

    puts ""
    puts "  #{match_count} matches in #{(elapsed * 1000).round(1)}ms"
    puts "  #{(match_count / elapsed).round(0)} matches/sec"

    # --- Summary -------------------------------------------------------------

    puts ""
    puts "=== Deltas ==="
    delta("compile (all patterns)", base,         after_compile)
    delta("100 matches",           after_curve,   after_match)
    delta("TOTAL",                  base,          after_match)

    ruby_compile_mb = (after_curve[:rss] - base[:rss]) / 1024.0
    ruby_compile_pss = ((after_curve[:pss] || 0) - (base[:pss] || 0)) / 1024.0
    rust_compile_mb = 536.0
    rust_per_pattern_kb = (rust_compile_mb * 1024 / 3905).round(1)
    ruby_per_pattern_kb = (ruby_compile_mb * 1024 / patterns.size).round(1)

    puts ""
    puts "=== Comparison with Rust (duckling gem) ==="
    puts ""
    puts "  Rust regex crate (all 49 locales, 3905 compilations):"
    puts "    ~#{rust_compile_mb.round(0)} MB   (Pss_Anon, Box::leak, permanent)"
    puts "    ~#{rust_per_pattern_kb} KB per pattern compilation"
    puts "  Ruby Regexp (#{patterns.size} unique patterns, compiled once):"
    puts "    #{ruby_compile_mb.round(1)} MB   (RSS delta, pinned via @pinned)"
    if pss_kb
      puts "    #{ruby_compile_pss.round(1)} MB   (PSS delta)"
      ratio = (rust_compile_mb / ruby_compile_pss).round(0)
    else
      ratio = (rust_compile_mb / ruby_compile_mb).round(0)
    end
    puts "    ~#{ruby_per_pattern_kb} KB per pattern compilation"
    puts ""
    puts "  Ratio: ~#{ratio}x less memory for Ruby Regexp"
    puts ""
    puts "  Why: Rust regex compiles to a hybrid DFA/NFA — the DFA pre-computes"
    puts "  all transition states for O(n) matching, but the compiled automaton"
    puts "  is large. Ruby Onigmo compiles to bytecode interpreted at match time"
    puts "  — much smaller representation, but O(nm) worst-case matching."
    puts ""
    puts "  The Rust side also recompiles shared 'common rules' per locale"
    puts "  (3905 total compilations vs 3418 unique patterns), since the cache"
    puts "  key includes the locale. Even normalizing for that, the per-pattern"
    puts "  cost differs by ~#{(rust_per_pattern_kb / ruby_per_pattern_kb).round(0)}x."

    print_smaps_rollup if File.exist?("/proc/self/smaps_rollup")
  end

  def print_smaps_rollup
    puts ""
    puts "=== /proc/self/smaps_rollup ==="
    puts File.read("/proc/self/smaps_rollup")
  end
end

RubyRegexpComparison.run
