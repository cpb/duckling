# Loads plan.yml and resolves the paths in it. Every stage starts here, so
# a stage never hardcodes a repo, an issue number, or a crate location.

require "yaml"
require "json"

module Plan
  PLAN_ROOT = File.expand_path("..", __dir__)
  REPO_ROOT = File.expand_path("../../..", PLAN_ROOT)

  class Config
    def initialize(path = File.join(PLAN_ROOT, "plan.yml"))
      @raw = YAML.safe_load_file(path)
    end

    def repo = @raw.fetch("repo")

    def parent_issue = @raw.fetch("parent_issue")

    def locale = @raw.dig("crate", "locale")

    def label(*keys) = keys.reduce(@raw.fetch("labels")) { |h, k| h.fetch(k.to_s) }

    def wave_of(variant)
      @raw.fetch("waves").each { |wave, list| return wave if list.include?(variant) }
      nil
    end

    def variants(wave) = @raw.fetch("waves").fetch(wave)

    def all_variants = @raw.fetch("waves").values.flatten

    def dependency_dimensions = @raw.fetch("dependency_dimensions")

    # The Cargo registry embeds a content hash in its directory name, so the
    # crate is found by glob. Failing loudly here beats every later stage
    # reporting an empty parse.
    def crate_path
      glob = File.expand_path(@raw.dig("crate", "path_glob"))
      found = Dir.glob(glob)
      if found.empty?
        abort "Crate not found at #{glob}\n" \
              "Run `cargo fetch` in ext/duckling/, or edit crate.path_glob in plan.yml."
      end
      found.first
    end

    def crate_name = @raw.dig("crate", "name")

    def crate_version = @raw.dig("crate", "version")

    # Corpus fixtures live in the repo once PR #255 merges. Until then they
    # are read out of its branch, which is why this returns parsed content
    # rather than a path.
    def corpus_cases
      extracted = read_fixture(@raw.dig("corpus", "extracted")).fetch("cases")
      extracted + local_cases
    end

    # After #256 the local additions are a directory of per-slice files.
    # Before it they are one file, which is what PR #255 still has, so both
    # layouts are read and the pipeline works either side of that split.
    def local_cases
      glob = Dir.glob(File.join(REPO_ROOT, @raw.dig("corpus", "local_glob")))
      return glob.flat_map { |f| JSON.parse(File.read(f)).fetch("cases", []) } unless glob.empty?

      single = @raw.dig("corpus", "local_glob").sub(%r{/\*\.json\z}, ".json")
      read_fixture(single).fetch("cases", [])
    rescue SystemExit
      []
    end

    private

    def read_fixture(rel)
      path = File.join(REPO_ROOT, rel)
      return JSON.parse(File.read(path)) if File.exist?(path)

      ref = @raw.dig("corpus", "fallback_ref")
      out = `git -C #{REPO_ROOT} show #{ref}:#{rel} 2>/dev/null`
      abort "Corpus fixture #{rel} not found in the working tree or at #{ref}." if out.empty?
      JSON.parse(out)
    end
  end

  def self.config = @config ||= Config.new
end
