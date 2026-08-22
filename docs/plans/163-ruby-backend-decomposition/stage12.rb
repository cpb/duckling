require_relative "gh"
require "json"
I = ids
P1 = I["p1"]; PARENT = I["phase3_parent"]
A1, B1, B2, A2 = I.fetch("a1"), I.fetch("b1"), I.fetch("b2"), I.fetch("a2")
CI = I["phase4"]["ci"]

# --- #166: now gated on the corpus stage ---
b = sh("gh", "issue", "view", P1.to_s, "-R", REPO, "--json", "body", "--jq", ".body")
insert = <<~MD

  ## Gated on the corpus stage, not just the spine

  **Do not run this until the corpus stage is finished**: ##{A1}, ##{B1}, ##{B2}, ##{A2}, and all 42 audits under ##{PARENT}.

  This script buckets whatever corpus exists at the moment it runs, and its output *is* every Phase 2 slice's spec. A case added after this runs does not reach any slice. That is the whole reason the audit was moved ahead of the port rather than left as Phase 3 — see ##{PARENT}.

  Expect a substantially larger corpus than #255's 1,662 cases: the sweep alone identified 140 unexercised branches, 11 uncovered rules, and a `with_latent:` axis with no coverage at all.
MD
b = b.sub("## The bucketing problem", insert + "\n## The bucketing problem")
File.write("/tmp/b166.md", b)
sh("gh", "issue", "edit", P1.to_s, "-R", REPO, "-F", "/tmp/b166.md")
puts "updated ##{P1}"

# --- #252: absorbs the residual differential ---
c = sh("gh", "issue", "view", CI.to_s, "-R", REPO, "--json", "body", "--jq", ".body")
add = <<~MD

  ## This absorbs what used to be Phase 3's differential

  The 42-way gap audit now runs *before* the port (##{PARENT}), so by the time Phase 2 finishes, the corpus already contains the cases that swarm would have added afterwards. There is no second swarm.

  What remains of the differential is exactly this issue: run the grown corpus against both backends and require both to pass. A slice that mis-ported something the audit added fails here, on a case that already existed when it was written — which is what makes the failure a straightforward bug rather than a discovery.

  Note the corpus this runs is **not** #255's 1,662 cases. It is that plus the corpus stage's additions, so size the CI budget against the grown fixture, not the merged one.
MD
c = c + add
File.write("/tmp/b252.md", c)
sh("gh", "issue", "edit", CI.to_s, "-R", REPO, "-F", "/tmp/b252.md")
puts "updated ##{CI}"
