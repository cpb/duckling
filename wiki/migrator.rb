#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"

module WikiMigration
  class TreeNode
    attr_reader :name, :parent, :subdirs, :files
    attr_accessor :prefix

    def initialize(name, parent = nil)
      @name = name
      @parent = parent
      @subdirs = {}
      @files = []
    end

    def add_file(path_parts, full_path)
      if path_parts.empty?
        raise "Empty path parts"
      elsif path_parts.size == 1
        @files << full_path
      else
        subdir_name = path_parts.first
        @subdirs[subdir_name] ||= TreeNode.new(subdir_name, self)
        @subdirs[subdir_name].add_file(path_parts[1..], full_path)
      end
    end
  end

  # Mechanizes the flatten + relink transform this repo has applied by hand:
  # GitHub wikis route pages by basename only (ignoring directory structure),
  # so every file gets a directory-prefixed, cased, and numbered page title
  # (e.g. "77.a.i. Raw Experiment Data"). This groups and orders them logically
  # in the sidebar. Internal relative links are rewritten to reference the
  # new cased, numbered page titles.
  class Migrator
    ENTRY_SLUG_RE = %r{\A(?:.*/)?(\d+)-(.+)\z}
    MD_LINK_RE = /\[([^\]]*)\]\(([^)\s]+)\)/
    MAX_TITLE_LENGTH = 120

    SUBDIR_STYLES = [:alpha, :roman, :numeric]
    FILE_STYLES = [:numeric, :roman, :numeric]

    CollisionError = Class.new(StandardError)

    attr_reader :docs_path, :entry_page_name, :issue_number

    def initialize(docs_path, entry_page_name: nil)
      @docs_path = docs_path.chomp("/")
      match = ENTRY_SLUG_RE.match(File.basename(@docs_path))
      raise ArgumentError, "#{docs_path} doesn't look like a docs/<issue>-<slug> tree" unless match

      @issue_number = match[1]
      @entry_page_name = entry_page_name || ENV["ENTRY_PAGE_NAME"] || match[2]
      @metadata = nil
    end

    def source_files
      @source_files ||= Dir.glob(File.join(docs_path, "**", "*.md")).sort
    end

    # {relative_path_within_tree => flattened_wiki_filename_without_extension}
    def wiki_names
      build_metadata! unless @metadata
      @wiki_names ||= source_files.each_with_object({}) do |path, memo|
        rel = relative_path(path)
        memo[rel] = @metadata.fetch(rel).fetch(:wiki_name)
      end
    end

    def h1(content)
      content[/^#\s+(.+)$/, 1]&.strip
    end

    def clean_title(h1_title)
      return nil if h1_title.nil?
      title = h1_title
        .gsub(/[`"'\/\\:*?<>|]/, "")
        .gsub(/\s+/, " ")
        .strip

      if title.length > MAX_TITLE_LENGTH
        truncated = title[0, MAX_TITLE_LENGTH - 1].rstrip
        return "#{truncated}…"
      end

      title
    end

    # {wiki_filename_with_extension => rewritten_markdown_content}
    def pages
      check_collisions!

      titles = source_files.each_with_object({}) do |path, memo|
        rel = relative_path(path)
        build_metadata! unless @metadata
        memo[rel] = @metadata.fetch(rel).fetch(:raw_h1) || @metadata.fetch(rel).fetch(:title)
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

    def to_alpha(index)
      result = ""
      while index >= 0
        result = ((index % 26) + 97).chr + result
        index = (index / 26) - 1
      end
      result
    end

    def to_roman(index)
      roman_mapping = {
        10 => "x", 9 => "ix", 5 => "v", 4 => "iv", 1 => "i"
      }
      result = ""
      n = index
      roman_mapping.each do |value, letters|
        while n >= value
          result += letters
          n -= value
        end
      end
      result
    end

    def format_index(val, style)
      case style
      when :alpha
        to_alpha(val)
      when :roman
        to_roman(val + 1)
      else
        (val + 1).to_s
      end
    end

    def build_metadata!
      @metadata = {}
      root_node = TreeNode.new(docs_path)
      source_files.each do |path|
        rel = relative_path(path)
        root_node.add_file(rel.split("/"), path)
      end
      assign_metadata(root_node, 0, nil)
    end

    def assign_metadata(node, depth, parent_prefix)
      if depth == 0
        node.prefix = @issue_number.to_s
      end

      # 1. Assign README.md
      readme = node.files.find { |f| File.basename(f) == "README.md" }
      if readme
        file_prefix = node.prefix
        raw_h1 = h1(File.read(readme))
        cleaned_title = clean_title(raw_h1) || clean_title(File.basename(readme, ".md").tr("-_", " "))
        if depth == 0
          cleaned_title = cleaned_title.sub(/\AIssue\s+#?\d+\s*[\u2014:-]\s*/i, "")
        end

        rel_path = relative_path(readme)
        @metadata[rel_path] = {
          prefix: file_prefix,
          raw_h1: raw_h1,
          title: cleaned_title,
          wiki_name: "#{file_prefix}. #{cleaned_title}"
        }
      end

      # 2. Assign other files in this directory (sorted alphabetically, case-insensitive)
      other_files = node.files.reject { |f| File.basename(f) == "README.md" }.sort_by { |f| File.basename(f).downcase }
      file_style = FILE_STYLES[depth % FILE_STYLES.size]
      other_files.each_with_index do |file_path, idx|
        file_prefix = "#{node.prefix}.#{format_index(idx, file_style)}"
        raw_h1 = h1(File.read(file_path))
        cleaned_title = clean_title(raw_h1) || clean_title(File.basename(file_path, ".md").tr("-_", " "))

        rel_path = relative_path(file_path)
        @metadata[rel_path] = {
          prefix: file_prefix,
          raw_h1: raw_h1,
          title: cleaned_title,
          wiki_name: "#{file_prefix}. #{cleaned_title}"
        }
      end

      # 3. Assign subdirectories and recurse
      subdirs = node.subdirs.sort_by { |name, _| name.downcase }
      subdir_style = SUBDIR_STYLES[depth % SUBDIR_STYLES.size]
      subdirs.each_with_index do |(name, subdir_node), idx|
        subdir_node.prefix = "#{node.prefix}.#{format_index(idx, subdir_style)}"
        assign_metadata(subdir_node, depth + 1, node.prefix)
      end
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
