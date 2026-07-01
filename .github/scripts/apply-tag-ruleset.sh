#!/usr/bin/env bash
# Creates or updates the GitHub tag ruleset that restricts v*.*.* tag
# creation/update to repo admins, preventing unauthorized release triggers
# (release.yml fires on any matching tag push). Safe to re-run.
#
# Requires: gh CLI authenticated with admin access to the target repo.
set -euo pipefail

repo="${1:-cpb/duckling}"
name="Protect release tags"

payload=$(cat <<'JSON'
{
  "name": "Protect release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/tags/v*.*.*"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "creation" },
    { "type": "update" }
  ],
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ]
}
JSON
)

existing_id=$(gh api "repos/${repo}/rulesets" --jq ".[] | select(.name == \"${name}\") | .id" || true)

if [ -n "${existing_id}" ]; then
  echo "Updating existing ruleset ${existing_id} on ${repo}..."
  echo "${payload}" | gh api "repos/${repo}/rulesets/${existing_id}" -X PUT --input -
else
  echo "Creating ruleset on ${repo}..."
  echo "${payload}" | gh api "repos/${repo}/rulesets" -X POST --input -
fi
