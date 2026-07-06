# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in duckling.gemspec
gemspec

gem "dotenv"
gem "irb"
gem "rake"

gem "minitest"

gem "standard"

# docs-to-wiki migration tooling (wiki:migrate / wiki:publish Rake tasks,
# invoked locally or via .github/workflows/docs-to-wiki.yml). Not yet
# published to RubyGems -- switch to a version constraint (e.g. "~> 0.1")
# once it is. Requires Ruby >= 3.3.0 to `bundle install`, stricter than
# duckling.gemspec's own >= 3.2.0 floor; see AGENTS.md's Gemfile entry.
gem "wiki_promoter", git: "https://github.com/cpb/wiki_promoter.git", branch: "main"
