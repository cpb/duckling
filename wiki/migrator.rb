#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"

module WikiMigration
  # Mechanizes the flatten + relink transform this repo has applied by hand
  # three times now when moving a docs/<issue>-slug/ research-and-planning
  # tree to the project wiki: GitHub wikis route pages by basename only
  # (ignoring directory structure), so every file gets a directory-prefixed,
  # dash-joined slug, and every internal link gets rewritten to that bare
  # slug with the target page's own H1 as its visible text -- never the
  # filename. Deliberately has no knowledge of git/gh -- that lives in the
  # Rakefile's wiki:publish task, keeping this module a pure "compute
  # flattened pages" unit that's easy to test.
  class Migrator
    ENTRY_SLUG_RE = %r{\A(?:.*/)?(\d+)-(.+)\z}
    MD_LINK_RE = /\[([^\]]*)\]\(([^)\s]+)\)/

    CollisionError = Class.new(StandardError)

    attr_reader :docs_path, :entry_page_name

    def initialize(docs_path, entry_page_name: nil)
      @docs_path = docs_path.chomp("/")
      match = ENTRY_SLUG_RE.match(File.basename(@docs_path))
      raise ArgumentError, "#{docs_path} doesn't look like a docs/<issue>-<slug> tree" unless match

      @issue_number = match[1]
      @entry_page_name = entry_page_name || ENV["ENTRY_PAGE_NAME"] || match[2]
    end

    def source_files
      @source_files ||= Dir.glob(File.join(docs_path, "**", "*.md")).sort
    end

    # {relative_path_within_tree => flattened_wiki_filename_without_extension}
    def wiki_names
      @wiki_names ||= source_files.each_with_object({}) do |path, memo|
        rel = relative_path(path)
        memo[rel] = flatten_name(rel)
      end
    end

    # docs/<issue>-slug/README.md                 -> entry_page_name
    # docs/<issue>-slug/research/README.md         -> "research"
    # docs/<issue>-slug/research/results.md        -> "research-results"
    def flatten_name(relative_path)
      return entry_page_name if relative_path == "README.md"

      dir = File.dirname(relative_path)
      base = File.basename(relative_path, ".md")
      dir_slug = (dir == ".") ? nil : dir.tr("/", "-")

      if base == "README"
        dir_slug || entry_page_name
      elsif dir_slug
        "#{dir_slug}-#{base}"
      else
        base
      end
    end

    def h1(content)
      content[/^#\s+(.+)$/, 1]&.strip
    end

    # {wiki_filename_with_extension => rewritten_markdown_content}
    def pages
      check_collisions!

      titles = source_files.each_with_object({}) do |path, memo|
        memo[relative_path(path)] = h1(File.read(path))
      end

      source_files.each_with_object({}) do |path, memo|
        rel = relative_path(path)
        content = rewrite_links(File.read(path), rel, titles)
        memo["#{wiki_names.fetch(rel)}.md"] = content
      end
    end

    private

    def relative_path(path)
      Pathname.new(path).relative_path_from(Pathname.new(docs_path)).to_s
    end

    def check_collisions!
      dupes = wiki_names.values.tally.select { |_, count| count > 1 }.keys
      return if dupes.empty?

      offenders = wiki_names.select { |_, name| dupes.include?(name) }
      raise CollisionError, "Multiple source files would flatten to the same wiki page: #{offenders}"
    end

    def rewrite_links(content, source_relative_path, titles)
      source_dir = File.dirname(source_relative_path)
      in_fence = false

      content.each_line.map do |line|
        if line.start_with?("```")
          in_fence = !in_fence
          next line
        end
        next line if in_fence

        line.gsub(MD_LINK_RE) do |match|
          text = $1
          target = $2
          resolved = resolve_internal_target(source_dir, target)
          next match unless resolved

          rel_target, anchor = resolved
          wiki_name = wiki_names[rel_target]
          next match unless wiki_name

          "[#{titles[rel_target] || text}](#{wiki_name}#{anchor})"
        end
      end.join
    end

    # Returns [relative_path_within_tree, "#anchor-or-empty"] if `target` is a
    # relative link to another .md file inside this tree, else nil (external
    # URL, anchor-only link, non-.md target, or a path that escapes the tree).
    def resolve_internal_target(source_dir, target)
      return nil if target.start_with?("#") || target =~ %r{\A[a-z][a-z0-9+.-]*://}i

      path, anchor = target.split("#", 2)
      return nil unless path&.end_with?(".md")

      base = (source_dir == ".") ? Pathname.new(docs_path) : Pathname.new(File.join(docs_path, source_dir))
      absolute = (base + path).cleanpath
      root = Pathname.new(docs_path).cleanpath
      return nil unless absolute.to_s.start_with?("#{root}/")

      rel = absolute.relative_path_from(root).to_s
      return nil unless wiki_names.key?(rel)

      [rel, anchor ? "##{anchor}" : ""]
    end
  end

  # Targeted literal find-and-replace for the one follow-up edit this repo's
  # migrations have consistently needed: repointing docs/2026-07-01-roadmap.md's
  # reference to a just-removed docs/<issue>-slug/ tree (bare relative path or
  # a full GitHub blob permalink into it) at the new wiki entry page. String
  # substitution only, not free-form prose rewriting -- keeps wiki:publish's
  # PR-branch edit predictable.
  def self.repoint_references(content, docs_path:, entry_url:)
    pattern = %r{
      (?:https://github\.com/cpb/duckling/blob/[^)\s"'\]]+/)?
      #{Regexp.escape(docs_path)}
      [^)\s"'\]]*
    }x
    content.gsub(pattern, entry_url)
  end
end
