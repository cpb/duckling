# Parses the pinned Rust crate. Three questions get asked of it repeatedly:
# what rules exist, what TimeForm variants exist, and what regex patterns a
# rule matches on. Everything here is regex-over-source, deliberately — the
# alternative is building the crate and instrumenting it, which #163 rules
# out for fixture capture and which would be far heavier here.

require_relative "config"

module Plan
  class Crate
    Rule = Struct.new(:name, :line, :patterns, :items, :builds, :mutates)

    def initialize(path = Plan.config.crate_path, locale: Plan.config.locale)
      @path = path
      @locale = locale
    end

    def time_en = File.join(@path, "src/dimensions/time/#{@locale}.rs")

    def time_mod = File.join(@path, "src/dimensions/time/mod.rs")

    def dimension_en(dim) = File.join(@path, "src/dimensions/#{dim}/#{@locale}.rs")

    # A rule is a `Rule { ... }` literal at eight spaces of indentation,
    # ending where its own braces balance.
    #
    # Balance, not "up to the next Rule {": the last rule in a file has no
    # next one, so a naive scan runs to EOF and swallows the helper
    # functions below. That silently mis-attributed "Mid-day" — which plainly
    # builds HourMinute(12, 0, false) — to Hour, because the helper
    # `apply_ampm` further down the file mentions Hour.
    def rules(file = time_en)
      lines = File.read(file).lines
      lines.each_index.select { |i| lines[i] =~ /^\s{8}Rule \{\s*$/ }.map do |start|
        parse_rule(lines[start..block_end(lines, start)].join, start + 1)
      end
    end

    # Which TimeForm variants exist, with the source excerpt for each. Doc
    # comments above a variant belong to it.
    def time_form_variants
      body = File.read(time_mod)[/pub enum TimeForm \{.*?\n\}/m].lines[1..-2]
      out = {}
      buffer = []
      depth = 0
      name = nil
      body.each do |line|
        buffer << line
        name = $1 if depth.zero? && line =~ /^\s{4}([A-Z][A-Za-z]*)\s*(?:\{|\(|,)/
        depth += line.count("{") - line.count("}")
        if name && depth.zero? && line =~ /(?:,|\},)\s*(?:\/\/.*)?$/
          out[name] = buffer.join.rstrip
          buffer = []
          name = nil
        end
      end
      out
    end

    def resolver_references(variant) = File.read(time_mod).scan(/TimeForm::#{variant}\b/).size

    private

    # Index of the line where the literal opened at `start` balances out.
    # Brace counting is enough here: the crate has no brace inside a string
    # or comment within a Rule literal, and a stray one would show up as a
    # rule whose name is nil.
    def block_end(lines, start)
      depth = 0
      (start...lines.size).each do |i|
        depth += lines[i].count("{") - lines[i].count("}")
        return i if depth.zero?
      end
      lines.size - 1
    end

    # `builds` is what the production closure constructs; `mutates` is which
    # TimeData attribute fields it writes. A rule with neither is neither a
    # constructor nor a modifier and wants looking at by hand.
    def parse_rule(block, line)
      production = block[/production:.*/m] || block
      builds = production.scan(/TimeData::(?:new|latent)\(\s*TimeForm::([A-Za-z]+)/).flatten
      builds << "Composed" if production.match?(/\bcompose\(|intersect_dom\(/)
      builds << "DateMDY" if production.match?(/\bmonth_day\(/)
      builds << "HourMinute" if production.match?(/apply_ampm\(/)

      Rule.new(
        name: block[/name:\s*"((?:[^"\\]|\\.)*)"/, 1],
        line: line,
        patterns: pattern_strings(block),
        items: pattern_section(block).scan(/\b(regex|predicate|dim)\s*\(/).flatten,
        builds: builds.uniq,
        mutates: %w[latent early_late open_interval_direction timezone direction ok_for_this_next]
          .select { |f| production.match?(/\.#{f}\s*=/) }
      )
    end

    def pattern_section(block) = block[/pattern:\s*vec!\[(.*?)\],\s*\n\s*production:/m, 1].to_s

    # Rust raw strings, `r"..."` and `r#"..."#`.
    def pattern_strings(block)
      pattern_section(block).scan(/r(\#*)"(.*?)"\1[\s,)\]]/m).map(&:last)
    end
  end

  # Rust `regex` and Onigmo differ in almost nothing that this crate uses.
  # The one systematic difference is named-group syntax. Measured over all
  # 276 EN rules: 276 translated, 0 errors.
  module RustRegex
    def self.to_ruby(pattern)
      Regexp.new(pattern.gsub("(?P<", "(?<"), Regexp::IGNORECASE)
    rescue RegexpError => e
      raise ArgumentError, "untranslatable: #{pattern.inspect} (#{e.message})"
    end
  end
end
