# frozen_string_literal: true

require "json"

# Merges the per-leg coverage resultsets and reports what no leg reached.
#
# The suite runs once per tz database (test/skip_manifest.yml). Each run's
# coverage is a statement about that database and nothing else, so a single
# leg's report answers the wrong question twice over: it calls code
# "uncovered" that another leg exercises thoroughly, and — the failure that
# motivated this — it says nothing at all about code that *no* leg reaches.
#
# The union across legs is the honest number. What this adds on top of the
# union is attribution: which legs reached a given line, and in particular
# which lines only one leg reaches. A line covered by exactly one leg is the
# whole justification for that leg existing; a line covered by zero is a claim
# in the source that nothing in CI has ever evaluated.
#
# The precedent for this analysis is test/support/skip_manifest.rb, and it
# covers the gap that one cannot. The manifest reasons about whole tests —
# skipped, or ran to completion. It cannot see inside a test that ran: a
# conditional whose `else` no leg takes runs green, reports as a pass, and
# asserts nothing. That is exactly what happened to
# `test_reference_zone_error_offers_the_backward_compat_remedy_only_where_relevant`,
# whose `else` branch — the only assertions on the remedy text — had never
# executed on any leg, on a test the manifest showed running everywhere.
module CoverageAnalysis
  ROOT = File.expand_path("../..", __dir__)

  # SimpleCov writes "[:if, 3, 73, 6, 76, 9]" — type, id, then the start and
  # end position of the branch. Ruby's Coverage module supplies the shape;
  # SimpleCov stringifies it for JSON, so it has to be parsed back.
  #
  # The type is not always bare: safe navigation is the symbol :"&.", which
  # inspects with quotes, and it is a branch like any other — `foo&.bar` on a
  # value that is never nil has an unreached nil arm.
  BRANCH_KEY = /\A\[:"?(?<type>[^,"]+)"?, (?<id>\d+), (?<start_line>\d+), (?<start_column>\d+), /

  # A line or branch, with the legs that executed it. `legs` empty is the
  # finding this whole file exists for.
  Finding = Struct.new(:file, :line, :label, :legs, :source) do
    def to_s
      "#{file}:#{line}  #{label}#{"  #{source.strip}" if source}"
    end

    # The label with its position stripped: "else of `if`", not "else of `if`
    # at line 310". What a manifest entry is matched on, and the reason for the
    # split — the enclosing branch's line is worth *showing*, but an entry
    # carrying it would rot on the first edit anywhere above the branch, which
    # is the churn that turns a declaration file into a rubber stamp.
    def kind
      label.sub(/ at line \d+\z/, "")
    end
  end

  module_function

  # Every leg that reported, as {leg_name => {file => {"lines" =>, "branches" =>}}}.
  #
  # Keyed on the command name recorded *inside* the resultset rather than on
  # the directory name, so a mis-collected artifact — a leg's report copied
  # into another leg's directory — reads as the leg that actually ran.
  def resultsets(dir = File.join(ROOT, "coverage"))
    Dir[File.join(dir, "*", ".resultset.json")].sort.each_with_object({}) do |path, legs|
      JSON.parse(File.read(path)).each do |command_name, result|
        if legs.key?(command_name)
          raise "#{command_name.inspect} coverage appears twice (second copy: #{path}). " \
            "Each leg reports once; two resultsets under one name cannot be attributed."
        end

        legs[command_name] = result.fetch("coverage")
      end
    end
  end

  # Files any leg reported on, relative to the repo root.
  def files(legs)
    legs.values.flat_map(&:keys).uniq.sort.map { |path| relative(path) }
  end

  def relative(path)
    path.sub("#{ROOT}/", "")
  end

  def absolute(file)
    File.join(ROOT, file)
  end

  # Per-line legs, as [line_number, [leg, ...]] for every *relevant* line —
  # one Ruby actually tracks, skipping blanks, comments and `end`.
  #
  # A leg that never loaded the file at all contributes nothing rather than
  # counting as a zero. Files under test/ are the case that matters: only the
  # legs whose run required a given test file can say anything about it, and
  # every leg requires every file, so this is a guard against a partial run
  # (a single-file `bin/test`) being merged in and reading as a blind spot.
  def line_legs(legs, file)
    path = absolute(file)
    tracked = legs.values.filter_map { |coverage| coverage[path]&.fetch("lines") }

    # `.to_i` rather than a guard on `tracked.empty?`: a file no leg reported
    # on yields an empty range and no findings, which is the same answer the
    # guard would give — and a guard nothing can reach would be the first
    # entry in this analysis's own manifest.
    (0...tracked.map(&:size).max.to_i).filter_map do |index|
      next if tracked.all? { |lines| lines[index].nil? }

      covering = legs.select { |_leg, coverage| coverage.dig(path, "lines", index).to_i.positive? }
      [index + 1, covering.keys]
    end
  end

  # Per-branch legs, as [line_number, label, [leg, ...]].
  #
  # A branch is identified by SimpleCov's own key, which encodes its position
  # and its id within the file. Positions move whenever the file does, so
  # merging across legs is only meaningful for resultsets taken from the same
  # source — which is what CI collects, all five legs running the same commit.
  def branch_legs(legs, file)
    path = absolute(file)
    keys = legs.values.flat_map { |coverage| coverage.dig(path, "branches")&.keys || [] }.uniq

    keys.filter_map { |outer|
      inner_keys = legs.values.flat_map { |coverage| coverage.dig(path, "branches", outer)&.keys || [] }.uniq

      inner_keys.map do |inner|
        covering = legs.select { |_leg, coverage| coverage.dig(path, "branches", outer, inner).to_i.positive? }
        [branch_line(inner), branch_label(outer, inner), covering.keys]
      end
    }.flatten(1).sort_by { |line, label, _| [line, label] }
  end

  def branch_line(key)
    Integer(key.match(BRANCH_KEY)[:start_line])
  end

  # "else of `if` at line 73" — the `if`'s own line is what a reader looks for,
  # since an implicit else has no line of its own to go to.
  def branch_label(outer, inner)
    "#{inner.match(BRANCH_KEY)[:type]} of `#{outer.match(BRANCH_KEY)[:type]}` at line #{branch_line(outer)}"
  end

  # Read as UTF-8 rather than in the default external encoding, which is what
  # the locale says and is US-ASCII on a bare CI runner. Ruby source is UTF-8
  # unless a magic comment says otherwise, and these files hold em dashes —
  # under US-ASCII the excerpt blows up on the first one.
  def source_lines(file)
    @source_lines ||= {}
    @source_lines[file] ||= File.readlines(absolute(file), encoding: "UTF-8")
  rescue Errno::ENOENT
    []
  end

  def source_line(file, line)
    source_lines(file)[line - 1]
  end

  # Everything no leg reached: the analysis's headline. A line here is either
  # dead, or alive only in a configuration nothing in CI runs.
  def unreached(legs)
    findings(legs) { |covering| covering.empty? }
  end

  # Everything some legs reached and others did not: the map of what actually
  # depends on which tz database. Not a defect list — this is what the legs
  # are for — but it is the list that says what each leg is buying, and a
  # finding here reached by exactly one leg is that leg's whole justification.
  #
  # Reported as "not all" rather than "exactly one" because how many legs
  # reach a given line is a property of the machine as much as of the leg: a
  # host whose own tzdata carries the backward-compat links (a GitHub runner)
  # and one that doesn't (this repo's dev container) split the same five legs
  # differently. "Some but not all" holds on both.
  def tz_dependent(legs)
    findings(legs) { |covering| covering.any? && covering.size < legs.size }
  end

  def findings(legs)
    files(legs).flat_map { |file|
      lines = line_legs(legs, file).filter_map do |line, covering|
        next unless yield(covering)

        Finding.new(file: file, line: line, label: "line", legs: covering, source: source_line(file, line))
      end

      branches = branch_legs(legs, file).filter_map do |line, label, covering|
        next unless yield(covering)

        Finding.new(file: file, line: line, label: label, legs: covering, source: source_line(file, line))
      end

      (lines + branches).sort_by { |finding| [finding.line, finding.label] }
    }
  end

  # Line and branch totals per leg and merged, as
  # {leg => {lines: [covered, total], branches: [covered, total]}} with
  # "merged" last.
  #
  # Every leg is counted against the *merged* denominator, not against its own
  # — the point of the table is to compare legs, and a leg measured only
  # against what it happened to load would score itself on a smaller exam.
  def summary(legs)
    covering_sets = files(legs).flat_map { |file|
      [line_legs(legs, file).map { |_line, covering| [:lines, covering] },
        branch_legs(legs, file).map { |_line, _label, covering| [:branches, covering] }]
    }.flatten(1)

    counts = ->(predicate) {
      %i[lines branches].to_h do |kind|
        of_kind = covering_sets.select { |kind_of_set, _| kind_of_set == kind }.map(&:last)
        [kind, [of_kind.count(&predicate), of_kind.size]]
      end
    }

    legs.keys.to_h { |leg| [leg, counts.call(->(covering) { covering.include?(leg) })] }
      .merge("merged" => counts.call(->(covering) { covering.any? }))
  end
end
