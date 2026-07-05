# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../wiki/migrator"

# These tests exercise WikiMigration::Migrator's pure flatten/relink logic
# against fixture trees -- they never touch git/gh or the real wiki repo
# (that's wiki:publish's job, smoke-tested by hand via `bin/worktree` or the
# docs-to-wiki workflow). One fixture is a frozen copy of PR #81's actual
# docs/77-spike-does-rb-nogvl-offload-safe-obviate-thread-wrapper/ tree, so
# the flatten/relink rules are verified against real content, not just
# synthetic paths.
class WikiMigratorTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("fixtures/wiki_migration", __dir__)
  PR81_TREE = File.join(FIXTURES_DIR, "77-spike-does-rb-nogvl-offload-safe-obviate-thread-wrapper")

  def write_tree(root, files)
    files.each do |relative_path, content|
      path = File.join(root, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  def test_entry_page_name_defaults_to_slug_verbatim
    migrator = WikiMigration::Migrator.new("docs/77-spike-does-rb-nogvl-offload-safe-obviate-thread-wrapper")
    assert_equal "spike-does-rb-nogvl-offload-safe-obviate-thread-wrapper", migrator.entry_page_name
  end

  def test_entry_page_name_override_wins
    migrator = WikiMigration::Migrator.new("docs/77-slug", entry_page_name: "custom-name")
    assert_equal "custom-name", migrator.entry_page_name
  end

  def test_rejects_a_path_without_a_leading_issue_number
    assert_raises(ArgumentError) { WikiMigration::Migrator.new("docs/not-numbered") }
  end

  def test_flatten_name_rules
    migrator = WikiMigration::Migrator.new("docs/1-slug", entry_page_name: "entry")
    assert_equal "entry", migrator.flatten_name("README.md")
    assert_equal "research", migrator.flatten_name("research/README.md")
    assert_equal "research-build-wiring", migrator.flatten_name("research/build-wiring/README.md")
    assert_equal "research-build-wiring-ci-configuration", migrator.flatten_name("research/build-wiring/ci-configuration.md")
  end

  def test_h1_extracts_first_heading_only
    migrator = WikiMigration::Migrator.new("docs/1-slug")
    content = "intro text\n# Real Title\nmore text\n# Not This One\n"
    assert_equal "Real Title", migrator.h1(content)
  end

  def test_pages_rewrites_internal_links_with_target_h1_as_text
    Dir.mktmpdir do |dir|
      tree = File.join(dir, "77-slug")
      write_tree(tree, {
        "README.md" => "# Entry Title\n\nSee [research/README.md](research/README.md) and [results](research/results.md#raw-data).\n",
        "research/README.md" => "# Research Title\n\nSee [results.md](results.md).\n",
        "research/results.md" => "# Results Title\n\nNo links here.\n"
      })

      pages = WikiMigration::Migrator.new(tree, entry_page_name: "entry").pages

      assert_equal %w[entry.md research-results.md research.md], pages.keys.sort
      assert_includes pages.fetch("entry.md"), "[Research Title](research)"
      assert_includes pages.fetch("entry.md"), "[Results Title](research-results#raw-data)"
      assert_includes pages.fetch("research.md"), "[Results Title](research-results)"
    end
  end

  def test_pages_leaves_external_links_and_code_fences_untouched
    Dir.mktmpdir do |dir|
      tree = File.join(dir, "1-slug")
      write_tree(tree, {
        "README.md" => <<~MD
          # Entry Title

          External: [duckling](https://github.com/wafer-inc/duckling).

          ```
          [fake link](other.md)
          ```
        MD
      })

      content = WikiMigration::Migrator.new(tree, entry_page_name: "entry").pages.fetch("entry.md")
      assert_includes content, "[duckling](https://github.com/wafer-inc/duckling)"
      assert_includes content, "[fake link](other.md)"
    end
  end

  def test_check_collisions_raises_when_two_sources_flatten_to_the_same_name
    Dir.mktmpdir do |dir|
      tree = File.join(dir, "1-slug")
      write_tree(tree, {
        "README.md" => "# Entry\n",
        "research.md" => "# Research Standalone\n",
        "research/README.md" => "# Research Nested\n"
      })

      error = assert_raises(WikiMigration::Migrator::CollisionError) do
        WikiMigration::Migrator.new(tree, entry_page_name: "entry").pages
      end
      assert_match(/research/, error.message)
    end
  end

  def test_repoint_references_replaces_relative_path_and_blob_permalink
    content = <<~MD
      See [research-ffi-risks](docs/1-slug/research/ffi-risks.md) and
      [background](https://github.com/cpb/duckling/blob/main/docs/1-slug/README.md#background).
    MD

    updated = WikiMigration.repoint_references(content, docs_path: "docs/1-slug", entry_url: "https://github.com/cpb/duckling/wiki/entry")

    refute_includes updated, "docs/1-slug"
    assert_equal 2, updated.scan("https://github.com/cpb/duckling/wiki/entry").size
  end

  def test_repoint_references_leaves_unrelated_content_untouched
    content = "See [the roadmap](https://github.com/cpb/duckling/blob/main/docs/2026-07-01-roadmap.md).\n"
    updated = WikiMigration.repoint_references(content, docs_path: "docs/1-slug", entry_url: "https://github.com/cpb/duckling/wiki/entry")
    assert_equal content, updated
  end

  # Integration-style check against PR #81's real docs tree (frozen fixture)
  # -- verifies the flatten/relink rules against real content, not just
  # synthetic paths.
  def test_pages_against_real_pr81_docs_tree
    migrator = WikiMigration::Migrator.new(PR81_TREE)
    pages = migrator.pages

    assert_equal "spike-does-rb-nogvl-offload-safe-obviate-thread-wrapper", migrator.entry_page_name
    assert_equal %w[
      research-results.md
      research.md
      spike-does-rb-nogvl-offload-safe-obviate-thread-wrapper.md
    ], pages.keys.sort

    entry = pages.fetch("spike-does-rb-nogvl-offload-safe-obviate-thread-wrapper.md")
    assert_includes entry, "[Research: `rb_nogvl` + `RB_NOGVL_OFFLOAD_SAFE` mechanism spike](research)"
    assert_includes entry, "[Raw experiment data](research-results)"
    assert_includes entry, "[Research: `rb_nogvl` + `RB_NOGVL_OFFLOAD_SAFE` mechanism spike](research#two-track-methodology)"
    # External permalinks must survive untouched
    assert_includes entry, "https://github.com/cpb/duckling/blob/main/ext/duckling/src/lib.rs"
    assert_includes entry, "https://github.com/cpb/duckling/wiki/research-async-reactor-blocking"

    research = pages.fetch("research.md")
    assert_includes research, "[Raw experiment data](research-results)"
  end
end
