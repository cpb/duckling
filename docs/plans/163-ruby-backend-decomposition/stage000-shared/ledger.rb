# Remembers which issue number each logical key got, so a stage that reruns
# edits what it made last time instead of creating a second copy.
#
# This is the whole idempotency story. Without it, rerunning stage220 mints
# 38 duplicate slice issues, and nothing in the GitHub API would object.

require "json"
require_relative "config"

module Plan
  module Ledger
    PATH = File.join(PLAN_ROOT, "issue-ledger.json")

    def self.all = File.exist?(PATH) ? JSON.parse(File.read(PATH)) : {}

    def self.[](key) = all[key.to_s]

    def self.fetch(key)
      all.fetch(key.to_s) do
        abort "No issue recorded for #{key.inspect}. Run the stage that creates it first " \
              "(see #{File.join(PLAN_ROOT, "README.md")})."
      end
    end

    def self.record(key, number)
      data = all
      data[key.to_s] = number
      File.write(PATH, JSON.pretty_generate(data) + "\n")
      number
    end

    def self.recorded?(key) = all.key?(key.to_s)
  end
end
