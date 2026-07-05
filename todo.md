Progress and remaining work — branch: cpb/docs-to-wiki

Current status
- Branch: cpb/docs-to-wiki (upstream: origin/cpb/docs-to-wiki)
- Modified but unstaged: AGENTS.md, Rakefile, test/wiki_migrator_test.rb, wiki/migrator.rb
- Staged: none
- Untracked: none
- Recent commits (most relevant):
  - 73204a4 wiki:publish: auto-update Home.md index when migrating a docs tree
  - 107fe09 Simplify test fixtures for wiki migration to keep only tested headers/links
  - 7f57de4 ✨ Automate docs/ → wiki migration (wiki:migrate/publish tasks + workflow)

Progress summary
- Core migration tasks and publish automation are present in history.
- Tests and fixtures were trimmed to focus on migration behavior.

Remaining work (high priority)
1. Finish migrator refactor: build TreeNode tree, recursively assign numeric/alpha/roman prefixes, strip leading "Issue #N" and colons, fallback to cased basenames when H1 missing.
2. Update test/wiki_migrator_test.rb expectations for alphabetical/roman sequencing and colon-stripping.
3. Update Rakefile wiki:publish and AGENTS.md to document the new naming conventions.
4. Run and fix failures from: `bundle exec rake test` and `bundle exec standardrb`.
5. Manual verification: `bundle exec rake "wiki:migrate[test/fixtures/wiki_migration/<issue-slug>]"` and inspect `tmp/wiki-migration/`.
6. Stage, commit, and open PR.

Next immediate steps (recommended)
- git add AGENTS.md Rakefile test/wiki_migrator_test.rb wiki/migrator.rb
- bundle exec rake test
- Run linter and fix style issues
- Commit and push, then open PR for review

Related session todo: implement-hierarchical-wiki-naming (pending). Mark in_progress when work begins.