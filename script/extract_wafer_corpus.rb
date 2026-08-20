#!/usr/bin/env ruby
# frozen_string_literal: true

# Extracts every check_* call site from a wafer-inc/duckling checkout's
# tests/*_corpus.rs files into test/fixtures/wafer_corpus.json.
#
# Run through `rake corpus:refresh`, which clones the pinned upstream ref
# first. See docs/wafer-corpus.md.

require "json"
require "optparse"
require "shellwords"

module WaferCorpus
  # Each entry maps an upstream `check_<name>` helper to the names of the
  # arguments that follow the text. `nil` marks a positional argument the
  # fixture records outside `expected` (the reference-time context).
  CHECKERS = {
    "time_naive" => %w[value grain],
    "time_instant" => %w[value grain],
    "time_interval" => %w[from to grain],
    "time_open_interval_after" => %w[value grain],
    "time_open_interval_before" => %w[value grain],
    "time_interval_with_context" => [nil, "from", "to", "grain"],
    "no_time" => [],
    "numeral" => %w[value],
    "ordinal" => %w[value],
    "email" => %w[value],
    "no_email" => [],
    "url" => %w[value domain],
    "no_url" => [],
    "phone" => %w[value],
    "no_phone" => [],
    "cc" => %w[value issuer],
    "no_cc" => [],
    "money" => %w[value unit],
    "distance" => %w[value unit],
    "volume" => %w[value unit],
    "temperature" => %w[value unit],
    "quantity" => %w[value unit],
    "quantity_with_product" => %w[value unit product],
    "duration" => %w[value grain],
    "no_duration" => []
  }.freeze

  # Longest name first, so `check_quantity_with_product(` never matches as
  # `check_quantity` plus leftovers, and `check_quantity_impl(` — an internal
  # helper, not a corpus case — matches nothing at all.
  CALL = /(?<!fn )\bcheck_(#{CHECKERS.keys.sort_by { |n| -n.length }.join("|")})\(/

  RUST_ESCAPES = {"n" => "\n", "t" => "\t", "r" => "\r", "0" => "\0", "\\" => "\\", "\"" => "\"", "'" => "'"}.freeze

  module_function

  # Rust string literals in the corpus are one-line and use only simple
  # escapes plus \u{...}.
  def unquote(literal)
    literal[1..-2]
      .gsub(/\\u\{([0-9a-fA-F]+)\}/) { [$1.to_i(16)].pack("U") }
      .gsub(/\\(.)/) { RUST_ESCAPES.fetch($1, $1) }
  end

  # Splits a call's argument list on the commas that separate arguments,
  # ignoring commas inside nested calls and inside string literals.
  def split_args(source)
    args = []
    current = +""
    depth = 0
    in_string = false
    escaped = false

    source.each_char do |char|
      if in_string
        current << char
        if escaped then escaped = false
        elsif char == "\\" then escaped = true
        elsif char == "\"" then in_string = false
        end
        next
      end

      case char
      when "\"" then in_string = true
      when "(", "[" then depth += 1
      when ")", "]" then depth -= 1
      when ","
        if depth.zero?
          args << current.strip
          current = +""
          next
        end
      end
      current << char
    end

    args << current.strip unless current.strip.empty?
    args
  end

  # Reads the argument list of a call whose opening paren is at `open`,
  # and returns [arguments, index just past the closing paren].
  def read_call(src, open)
    depth = 0
    in_string = false
    escaped = false
    index = open

    while index < src.length
      char = src[index]
      if in_string
        if escaped then escaped = false
        elsif char == "\\" then escaped = true
        elsif char == "\"" then in_string = false
        end
      else
        case char
        when "\"" then in_string = true
        when "(" then depth += 1
        when ")"
          depth -= 1
          break if depth.zero?
        end
      end
      index += 1
    end

    raise "Unbalanced call starting at offset #{open}" unless depth.zero?
    [split_args(src[(open + 1)...index]), index + 1]
  end

  # dt(y, m, d, h, mi, s) and local_datetime(offset, y, m, d, h, mi, s) are
  # the only calls the corpus passes as expectations. Both become a
  # [year, month, day, hour, minute, second] wall-clock array.
  def parse_expectation(argument)
    case argument
    when /\A"/ then unquote(argument)
    when /\Adt\((.*)\)\z/m then $1.split(",").map { |part| Integer(part.strip) }
    when /\Alocal_datetime\((.*)\)\z/m then $1.split(",").drop(1).map { |part| Integer(part.strip) }
    when /\A-?\d+\z/ then Integer(argument)
    when /\A-?\d+\.\d+\z/ then Float(argument)
    else raise "Unrecognized corpus argument #{argument.inspect}"
    end
  end

  # The with-context checkers take `&ctx`, a local bound earlier in the same
  # `#[test] fn` by one of the `make_<name>_context()` helpers. Resolve it to
  # that helper's name; the runner holds the reference times themselves,
  # because they live in Rust code the extractor does not evaluate.
  def context_before(src, offset)
    name = src[0...offset][/.*let\s+ctx\s*=\s*make_(\w+)_context\(\)/m, 1]
    raise "No make_*_context() binding before offset #{offset}" unless name
    name
  end

  # True when the call site sits behind a `//` on its own line. The corpus
  # has no block comments.
  def commented_out?(src, offset)
    line_start = src.rindex("\n", offset)
    line_start = line_start ? line_start + 1 : 0
    src[line_start...offset].include?("//")
  end

  def enclosing_test(src, offset)
    src[0...offset][/.*^\s*fn\s+(\w+)\s*\(/m, 1] || "unknown"
  end

  def extract_file(path)
    src = File.read(path, encoding: "UTF-8")
    file = File.basename(path)
    cases = []
    cursor = 0

    while (match = CALL.match(src, cursor))
      check = match[1]
      arguments, cursor = read_call(src, match.end(0) - 1)
      names = CHECKERS.fetch(check)

      # The checker definitions declare the same names; only calls carry a
      # string literal as their first argument.
      next unless arguments.first&.start_with?('"')

      # time_corpus.rs keeps 24 latent-mode cases commented out. They need
      # with_latent, which no corpus checker passes, so they are not cases.
      next if commented_out?(src, match.begin(0))

      text = unquote(arguments.first)
      rest = arguments.drop(1)
      unless rest.length == names.length
        raise "check_#{check} in #{file} takes #{names.length} expectations, got #{rest.length}: #{arguments.inspect}"
      end

      context = nil
      expected = {}
      names.zip(rest).each do |name, argument|
        if name.nil?
          context = context_before(src, match.begin(0))
        else
          expected[name] = parse_expectation(argument)
        end
      end

      cases << {
        "file" => file,
        "line" => src[0...match.begin(0)].count("\n") + 1,
        "group" => enclosing_test(src, match.begin(0)),
        "check" => check,
        "text" => text,
        "context" => context,
        "expected" => expected
      }.compact
    end

    cases
  end

  def extract(upstream_dir)
    paths = Dir[File.join(upstream_dir, "tests", "*_corpus.rs")].sort
    raise "No tests/*_corpus.rs under #{upstream_dir}" if paths.empty?

    # pending_corpus.rs holds cases upstream knows fail; see docs/wafer-corpus.md.
    paths.reject { |path| File.basename(path) == "pending_corpus.rs" }.flat_map { |path| extract_file(path) }
  end

  def upstream_sha(upstream_dir)
    sha = `git -C #{upstream_dir.shellescape} rev-parse HEAD`.strip
    raise "Could not read HEAD of #{upstream_dir}" unless $?.success? && !sha.empty?
    sha
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    upstream: nil,
    output: File.expand_path("../test/fixtures/wafer_corpus.json", __dir__)
  }

  OptionParser.new do |parser|
    parser.banner = "Usage: script/extract_wafer_corpus.rb --upstream DIR [--output FILE]"
    parser.on("--upstream DIR", "Path to a wafer-inc/duckling checkout") { |value| options[:upstream] = value }
    parser.on("--output FILE", "Fixture to write") { |value| options[:output] = value }
  end.parse!

  abort "--upstream is required" unless options[:upstream]

  cases = WaferCorpus.extract(options[:upstream])
  sha = WaferCorpus.upstream_sha(options[:upstream])

  # One case per line: the fixture is reviewed and diffed by hand after each
  # refresh, and pretty-printing 1,600 nested objects hides what changed.
  lines = cases.map { |kase| "    #{JSON.generate(kase)}" }
  # Explicit UTF-8: the corpus carries an em dash and a cent sign, and a
  # host whose default external encoding is US-ASCII must not mangle them.
  File.write(options[:output], <<~JSON, encoding: "UTF-8")
    {
      "upstream": {
        "repo": "https://github.com/wafer-inc/duckling",
        "sha": #{JSON.generate(sha)},
        "license": "BSD-3-Clause",
        "source": "tests/*_corpus.rs"
      },
      "generator": "script/extract_wafer_corpus.rb",
      "case_count": #{cases.length},
      "cases": [
    #{lines.join(",\n")}
      ]
    }
  JSON

  warn "Wrote #{cases.length} cases from #{sha[0, 7]} to #{options[:output]}"
end
