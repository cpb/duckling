# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../wiki/migrator"

class WikiMigratorEdgecasesTest < Minitest::Test
  def write_tree(root, files)
    files.each do |relative_path, content|
      path = File.join(root, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  def test_missing_h1_fallback_to_basename
    Dir.mktmpdir do |dir|
      tree = File.join(dir, "1-slug")
      write_tree(tree, {
        "README.md" => "", # no H1 present
        "other.md" => "# Has H1\n"
      })

      pages = WikiMigration::Migrator.new(tree).pages
      # README fallback should use basename ("README") after tr("-_," " ") and cleaning
      assert_includes pages.keys, "1. README.md"
    end
  end

  def test_long_h1_truncation
    long_title = "A" * 200
    Dir.mktmpdir do |dir|
      tree = File.join(dir, "1-slug")
      write_tree(tree, {
        "README.md" => "# #{long_title}\n"
      })

      pages = WikiMigration::Migrator.new(tree).pages
      name = pages.keys.find { |k| k.start_with?("1. ") }
      assert name, "expected a generated page name"
      title_part = name.sub(/^1\.\s+/, "").sub(/\.md$/, "")
      # Title should end with ellipsis and be <= MAX_TITLE_LENGTH
      assert title_part.end_with?("…")
      assert title_part.length <= WikiMigration::Migrator::MAX_TITLE_LENGTH + 10, "title part unexpectedly long"
    end
  end

  def test_clean_title_collapses_spaces_and_strips_colons
    # call clean_title directly to assert behavior
    mt = WikiMigration::Migrator.new("docs/1-slug")
    cleaned = mt.send(:clean_title, "This:  is   a\ttest : with:colons")
    assert_equal "This is a test withcolons", cleaned
  end
end
