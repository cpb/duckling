# Every GitHub mutation the pipeline makes, in one place, so a stage reads
# as "what to say" rather than "how to say it to gh(1)".
#
# Create is idempotent through the ledger: a key that already has a number
# is edited, not recreated.

require "json"
require "tempfile"
require_relative "config"
require_relative "ledger"

module Plan
  module GitHub
    module_function

    def sh(*args)
      out = IO.popen(args, err: [:child, :out], &:read)
      raise "gh failed: #{args.join(" ")}\n#{out}" unless $?.success?
      out
    end

    def repo = Plan.config.repo

    # Creates the issue the first time, edits it every time after. `key` is
    # the pipeline's own name for the issue, not GitHub's.
    # DRY_RUN=1 prints what would be sent and touches nothing. Worth using
    # before any run that creates issues — there is no undo for 42 of them.
    def dry_run? = ENV["DRY_RUN"] == "1"

    def upsert(key:, title:, body:, labels: [], parent: nil)
      if dry_run?
        puts "\n#{"=" * 76}\n#{Ledger[key] ? "EDIT ##{Ledger[key]}" : "CREATE"}  key=#{key}"
        puts "title:  #{title}"
        puts "labels: #{labels.join(", ")}"
        puts "#{"-" * 76}\n#{body}"
        return Ledger[key] || 0
      end

      Tempfile.create(["issue", ".md"]) do |f|
        f.write(body)
        f.flush
        number = Ledger[key]
        if number
          sh("gh", "issue", "edit", number.to_s, "-R", repo, "-t", title, "-F", f.path)
          sync_labels(number, labels)
        else
          url = sh("gh", "issue", "create", "-R", repo, "-t", title, "-F", f.path,
            *labels.flat_map { |l| ["-l", l] }).lines.grep(%r{https://}).last.to_s.strip
          number = Integer(url[%r{/(\d+)\z}, 1])
          Ledger.record(key, number)
          link(parent, number) if parent
        end
        number
      end
    end

    def sync_labels(number, labels)
      return if dry_run?
      return if labels.empty?
      sh("gh", "issue", "edit", number.to_s, "-R", repo, *labels.flat_map { |l| ["--add-label", l] })
    end

    # GitHub's sub-issue API keys on the database id, not the issue number.
    def database_id(number) = Integer(sh("gh", "api", "repos/#{repo}/issues/#{number}", "--jq", ".id").strip)

    def link(parent, child)
      return if dry_run?
      existing = sh("gh", "api", "repos/#{repo}/issues/#{parent}/sub_issues", "--paginate",
        "--jq", ".[].number").split.map(&:to_i)
      return if existing.include?(child)
      sh("gh", "api", "repos/#{repo}/issues/#{parent}/sub_issues", "-F", "sub_issue_id=#{database_id(child)}")
    end

    def body_of(number) = sh("gh", "issue", "view", number.to_s, "-R", repo, "--json", "body", "--jq", ".body")

    def replace_body(number, body)
      return if dry_run?
      Tempfile.create(["issue", ".md"]) do |f|
        f.write(body)
        f.flush
        sh("gh", "issue", "edit", number.to_s, "-R", repo, "-F", f.path)
      end
    end

    # Comments are not idempotent — GitHub has no upsert — so a marker line
    # identifies the pipeline's own comment and edits it in place.
    def upsert_comment(number, marker, body)
      return if dry_run?
      full = "#{body}\n\n<!-- #{marker} -->"
      found = JSON.parse(sh("gh", "issue", "view", number.to_s, "-R", repo, "--json", "comments"))
        .fetch("comments").find { |c| c["body"].to_s.include?("<!-- #{marker} -->") }
      Tempfile.create(["comment", ".md"]) do |f|
        f.write(full)
        f.flush
        if found
          sh("gh", "api", "-X", "PATCH", "repos/#{repo}/issues/comments/#{found.fetch("url")[%r{/(\d+)\z}, 1]}",
            "-F", "body=@#{f.path}")
        else
          sh("gh", "issue", "comment", number.to_s, "-R", repo, "-F", f.path)
        end
      end
    end

    def ensure_label(name, color:, description:)
      sh("gh", "label", "create", name, "-R", repo, "--color", color, "--description", description)
    rescue RuntimeError => e
      raise unless e.message.include?("already exists")
    end
  end
end
