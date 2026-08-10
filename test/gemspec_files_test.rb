# frozen_string_literal: true

require "minitest/autorun"

# Guards duckling.gemspec's packaged file list. The gemspec builds spec.files
# from `git ls-files`, so anything tracked in git is one forgetful commit away
# from shipping — 0.3.0–0.4.0 packaged .claude/settings.json, AGENTS.md and
# CLAUDE.md exactly that way, under a reject-list that named what to keep out.
# The gemspec now allow-lists what ships; these tests are the tripwire if the
# list or a future rework lets agent/tooling files back in.
#
# Loads the gemspec and nothing else — no extension build, no test_helper — so
# it also runs standalone with plain ruby, from the repository root:
#
#   ruby test/gemspec_files_test.rb
#
# Loading the gemspec shells out to `git ls-files`, and RubyGems answers nil
# rather than raising when that fails, so a checkout without git gets a clear
# error from spec_files instead of a confusing empty-list failure.
class GemspecFilesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # Agent sessions and their configuration: Claude Code, Codex, and the
  # AGENTS.md/CLAUDE.md convention other tools read. Kept deliberately broader
  # than what this repo uses today — the gem is no place for any of them.
  AGENT_FILE_PATTERN = %r{(^|/)\.(claude|codex|agents|cursor|windsurf)(/|$)|(^|/)(AGENTS|CLAUDE|GEMINI)\.md$}i

  def test_no_agent_files_ship_in_the_gem
    offenders = spec_files.grep(AGENT_FILE_PATTERN)

    assert_empty offenders, "gem would package agent files: #{offenders.join(", ")}"
  end

  def test_no_dotfiles_ship_in_the_gem
    offenders = spec_files.select { |f| f.start_with?(".") || f.include?("/.") }

    assert_empty offenders, "gem would package dotfiles: #{offenders.join(", ")}"
  end

  # An allow-list fails the other way too: a rename that drops lib/ or the
  # Rust sources out of the gem passes both tests above while shipping an
  # empty package. Pin the load-bearing entries so that mistake fails here.
  def test_gem_still_carries_what_it_needs
    %w[
      lib/duckling.rb
      lib/duckling/version.rb
      ext/duckling/extconf.rb
      ext/duckling/Cargo.toml
      ext/duckling/src/lib.rs
      Cargo.toml
      Cargo.lock
      README.md
      LICENSE.txt
      CHANGELOG.md
    ].each do |f|
      assert_includes spec_files, f, "gem no longer packages #{f}"
    end
  end

  private

  def spec_files
    @spec_files ||= begin
      spec = Gem::Specification.load(File.join(ROOT, "duckling.gemspec"))
      raise "could not load duckling.gemspec — is `git` on PATH?" if spec.nil?

      spec.files
    end
  end
end
