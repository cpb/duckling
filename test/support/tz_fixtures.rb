# frozen_string_literal: true

require "fileutils"
require "tzinfo"

# Compiles test/fixtures/tz/*.zi into a private zoneinfo directory and points
# TZInfo at it, so the DST edges the suite cares about can be asserted without
# depending on any real zone.
#
# Real zones are a poor foundation for this coverage twice over: which of them
# exist depends on the datasource (a stock Ubuntu host is missing the
# backward-compat links), and what they do depends on the vintage (Greenland's
# rules changed in 2023a). A fixture zone compiled at test time has neither
# problem — it is identical on every host, and the fixture directory exposes
# only its own three identifiers, so nothing about the host's tz database can
# leak into a test that uses it.
#
# TZInfo::DataSource.set clears the timezone cache and is fully reversible
# in-process, so this needs no separate process or rake task — see
# `with_fixture_datasource`.
module TZFixtures
  SOURCE_DIR = File.expand_path("../fixtures/tz", __dir__)
  BUILD_DIR = File.expand_path("../../tmp/tz-fixtures", __dir__)

  # zic lives in sbin on most distributions, which is not on a non-root
  # PATH. Look there explicitly rather than making every caller export one.
  ZIC_SEARCH_PATH = ["/usr/sbin", "/sbin", "/usr/bin", "/bin"].freeze

  module_function

  # Path to the compiled fixture zoneinfo directory, built once per process.
  def zoneinfo_dir
    @zoneinfo_dir ||= build!
  end

  # Runs the block with the fixture zones as the process-wide tz datasource,
  # restoring the previous one afterwards. Process-wide is the only option:
  # TZInfo::DataSource is a global, and reference_zone: reaches it through
  # TZInfo::Timezone.get deep inside Duckling.parse rather than through
  # anything a test could inject. That is also why these are fixture *zones*
  # rather than Ruby doubles — a double can only reach local_time_in_zone
  # directly, which stops short of the outside-in path through Duckling.parse.
  def with_fixture_datasource
    previous = TZInfo::DataSource.get
    TZInfo::DataSource.set(:zoneinfo, zoneinfo_dir)
    yield
  ensure
    TZInfo::DataSource.set(previous)
  end

  def build!
    FileUtils.rm_rf(BUILD_DIR)
    FileUtils.mkdir_p(BUILD_DIR)
    FileUtils.cp(Dir[File.join(SOURCE_DIR, "*.tab")], BUILD_DIR)

    Dir[File.join(SOURCE_DIR, "*.zi")].sort.each do |source|
      system(zic, "-b", "fat", "-d", BUILD_DIR, source, exception: true)
    end

    BUILD_DIR
  end

  # Deliberately a hard error rather than a skip when zic is missing. These
  # fixtures exist because the coverage they carry kept degrading silently on
  # hosts nobody was looking at; letting them vanish on a host without zic
  # would reintroduce exactly that. zic ships with the tzdata package, which
  # is installed on every GitHub Actions runner and on macOS.
  def zic
    @zic ||= ENV["ZIC"] || ZIC_SEARCH_PATH.map { |dir| File.join(dir, "zic") }.find { |path| File.executable?(path) } ||
      raise("zic not found in #{ZIC_SEARCH_PATH.join(", ")}. Install the tzdata package, or set ZIC to its path.")
  end
end
