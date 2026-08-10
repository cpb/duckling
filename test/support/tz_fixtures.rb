# frozen_string_literal: true

require "fileutils"
require "tzinfo"

# Compiles test/fixtures/tz/*.zi into a private zoneinfo directory and points
# TZInfo at it: the same DST edges on every host and every vintage.
# See docs/tz-database-axis.md.
module TZFixtures
  # The datasource is process-global (timezone_for reaches it through
  # TZInfo::Timezone.get inside Duckling.parse), so the teardown restore is
  # mandatory. DataSource.get raises when no source exists, so setup
  # tolerates the absence and teardown restores conditionally (set(nil)
  # raises).
  module Datasource
    def setup
      super
      @previous_datasource = begin
        TZInfo::DataSource.get
      rescue TZInfo::DataSourceNotFound
        nil
      end
      TZInfo::DataSource.set(:zoneinfo, TZFixtures.zoneinfo_dir)
    end

    def teardown
      TZInfo::DataSource.set(@previous_datasource) if @previous_datasource
      super
    end
  end

  SOURCE_DIR = File.expand_path("../fixtures/tz", __dir__)
  BUILD_DIR = File.expand_path("../../tmp/tz-fixtures", __dir__)

  # zic lives in sbin, which is off a non-root PATH.
  ZIC_SEARCH_PATH = ["/usr/sbin", "/sbin", "/usr/bin", "/bin"].freeze

  module_function

  def zoneinfo_dir
    @zoneinfo_dir ||= build!
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

  # zic comes from libc-bin on Debian/Ubuntu and is stock on macOS. A missing
  # zic is a hard error.
  def zic
    @zic ||= ENV["ZIC"] || ZIC_SEARCH_PATH.map { |dir| File.join(dir, "zic") }.find { |path| File.executable?(path) } ||
      raise("zic not found in #{ZIC_SEARCH_PATH.join(", ")}. It comes from libc-bin on " \
            "Debian/Ubuntu and is stock on macOS; set ZIC to its path if it lives elsewhere.")
  end
end
