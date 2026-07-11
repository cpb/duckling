# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in duckling.gemspec
gemspec

gem "dotenv"
gem "irb"
gem "rake"

gem "minitest"

gem "standard"

# Wiki promotion tooling (wiki:migrate / wiki:publish Rake tasks,
# invoked locally or via .github/workflows/promote-wiki.yml). Requires
# Ruby >= 3.3.0 to `bundle install`, stricter than duckling.gemspec's own
# >= 3.2.0 floor; see AGENTS.md's Gemfile entry.
gem "wiki_promoter", "~> 0.1"
