# frozen_string_literal: true

# Line and branch coverage for one tz leg, written where the cross-leg
# analysis can find it.
#
# Off unless DUCKLING_COVERAGE=1, and required before anything else so
# `lib/duckling.rb` is loaded with the counters already running. A plain
# `bundle exec rake` pays nothing for this.
return unless ENV["DUCKLING_COVERAGE"] == "1"

require "simplecov"

# The suite runs once per tz database (see test/skip_manifest.yml), and a leg
# is exactly the thing that decides which branches are reachable: the
# backward-compat remedy in `unknown_identifier_diagnosis` cannot execute on a
# database that has the links, and the assertions on that remedy cannot
# execute either. So each leg keeps its own resultset and the analysis merges
# them — one directory per leg, because CI collects them from separate jobs.
leg = ENV.fetch("DUCKLING_TZ_LEG", "tzinfo-data")

SimpleCov.start do
  enable_coverage :branch
  command_name leg

  # One directory per leg, holding that leg's own `.resultset.json`. Merging
  # is the analysis's job, not SimpleCov's: its merge is time-windowed
  # (`merge_timeout`) and keyed on command name within a single directory,
  # while these runs happen minutes apart, in separate CI jobs, on separate
  # machines. Keeping them apart also means each leg's own HTML report stays
  # readable on its own.
  coverage_dir File.join("coverage", leg)

  # Files that the suite never loads at all still have to appear, or a
  # module nothing requires reads as perfect coverage by absence.
  track_files "lib/**/*.rb"

  # SimpleCov hides test/ by default, on the reasoning that a test suite runs
  # 100% of its own test files. That reasoning stops holding here. The same
  # suite runs against five tz databases, and a conditional inside a test is a
  # claim about which one it got — so an `else` no leg reaches is a test
  # asserting nothing, anywhere, which is precisely what this analysis is for.
  remove_filter %r{\A(test|features|spec|autotest)/}

  # Everything else is out of scope: bin/ and ext/ hold no Ruby the suite
  # loads, and benchmark/ is a harness whose numbers this axis does not move.
  add_filter %r{\A(bin|benchmark|ext|tmp|vendor)/}

  add_group "lib", "lib/"
  add_group "test", "test/"
end
