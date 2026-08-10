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
# in-process, so this needs no separate process or rake task. Include
# TZFixtures::Datasource in a test class to swap to the fixture zones for the
# duration of each of its tests.
module TZFixtures
  # The swap itself, as setup/teardown rather than a block: TZInfo::DataSource
  # is process-global and minitest gives no block around a test, so a
  # block-form helper could not be called from where the swap has to happen.
  #
  # Process-global is not a choice — reference_zone: reaches the datasource
  # through TZInfo::Timezone.get deep inside Duckling.parse, not through
  # anything a test could inject. That is also why these are fixture *zones*
  # rather than Ruby doubles: a double can only reach local_time_in_zone
  # directly, which stops short of the outside-in path through Duckling.parse.
  #
  # The restore is mandatory, not hygiene. Leave the fixture datasource
  # installed and every later test in the process resolves against three zones
  # and nothing else.
  # The fixture zones are compiled locally by zic and need nothing from the
  # host but the compiler, so these tests must run on a host with no tz
  # database — that independence is the whole reason they exist. But
  # TZInfo::DataSource.get *creates* the default source when none is set, and
  # raises when it can't, so capturing the previous one has to tolerate there
  # not being one. Restoring is then conditional: `set(nil)` raises
  # ArgumentError, which on a failed setup would replace the real error with a
  # worse one.
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

  # zic lives in sbin on most distributions, which is not on a non-root
  # PATH. Look there explicitly rather than making every caller export one.
  ZIC_SEARCH_PATH = ["/usr/sbin", "/sbin", "/usr/bin", "/bin"].freeze

  module_function

  # Path to the compiled fixture zoneinfo directory, built once per process.
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

  # Deliberately a hard error rather than a skip when zic is missing. These
  # fixtures exist because the coverage they carry kept degrading silently on
  # hosts nobody was looking at; letting them vanish on a host without zic
  # would reintroduce exactly that.
  #
  # In practice it is never missing on a host this suite runs on. Note that
  # the compiler and the data come from different packages: on Debian and
  # Ubuntu zic belongs to `libc-bin` (Priority: required, a dependency of
  # libc6), *not* to `tzdata` — so even a slim image with no
  # /usr/share/zoneinfo still has zic. macOS ships /usr/sbin/zic as a stock
  # utility, with no Homebrew formula needed.
  def zic
    @zic ||= ENV["ZIC"] || ZIC_SEARCH_PATH.map { |dir| File.join(dir, "zic") }.find { |path| File.executable?(path) } ||
      raise("zic not found in #{ZIC_SEARCH_PATH.join(", ")}. It comes from libc-bin on " \
            "Debian/Ubuntu and is stock on macOS; set ZIC to its path if it lives elsewhere.")
  end
end
