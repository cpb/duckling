require_relative "gh"
require "json"
I = ids
SL = JSON.parse(File.read(File.join(__dir__, "slices.json")))
P2 = I["phase2"]; P3 = I["phase3"]; DM = I["dims"]; P4 = I["phase4"]

rows = SL.map do |s|
  ["| `#{s["key"] == "Modifiers" ? "(modifiers)" : s["key"]}` | #{s["wave"]} | #{s["rules"].size} | ##{P2[s["key"]]} | ##{P3[s["key"]]} |", s["wave"], -s["rules"].size, s["key"]]
end
%w[numeral duration ordinal time_grain].each_with_index do |d, i|
  n = [23, 20, 4, 8][i]
  rows << ["| #{d} (dim) | A | #{n} | ##{DM[d]} | ##{P3["dim:#{d}"]} |", "A", -n, d]
end
tbl = rows.sort_by { |r| [r[1], r[2], r[3]] }.map(&:first).join("\n")

body = <<~MD
  ## Broken out into 91 subtasks

  The phases and slices of this issue are now sub-issues, so the orchestrating agent picks work off a list instead of re-deriving the slicing. Everything below was derived from the pinned crate (duckling 0.4.0) rather than restated from this issue.

  ### Pick order

  | Stage | Issues | Gate |
  |---|---|---|
  | Phase 0 — spine | ##{I["p0"]} | blocks everything; one agent, serial |
  | Phase 0 — ranking | ##{I["rank"]} | needs ##{I["p0"]}; then parallel with Phase 1 and Wave A |
  | Phase 1 — fixture capture | ##{I["p1"]} | needs ##{I["p0"]}; blocks all of Phase 2 |
  | Phase 2 — Wave A | 30 issues, `label:wave-a` | needs ##{I["p0"]} + ##{I["p1"]}; **no ordering inside the wave** |
  | Phase 2 — Wave B | 9 issues, `label:wave-b` | needs Wave A green |
  | Phase 2 — Wave C | 3 issues, `label:wave-c` | needs Wave B green |
  | Phase 3 — gap audit | ##{I["phase3_parent"]} + 42 under it | needs **all** of Phase 2 green |
  | Phase 4 — reduce | ##{P4["ci"]} → ##{P4["measure"]} → ##{P4["forecast"]} | strictly serial |

  ```
  gh issue list --label wave-a --state open    # the 30-way fan-out
  gh issue list --label phase-3 --state open   # the 42-way audit
  ```

  ### Two things the derivation turned up that this issue's plan did not cover

  **1. 23 of the 221 EN rules construct no `TimeForm` at all.** They clone a `TimeData` and mutate its attribute fields — `latent`, `early_late`, `open_interval_direction`, `timezone`, `direction`. `until <time>`, `late/early/mid <time>`, `<time> timezone`, `next <time>` and 19 others. The 37-variant slicing has no home for them, so every variant slice would either skip them or all reach for them at once. They are now a 38th slice: ##{P2["Modifiers"]} (audit: ##{P3["Modifiers"]}). It carries no resolver and no `time/forms/` file.

  **2. Rule mass is lopsided, and the heavy end sits in the last wave.** `Composed` (34 rules) and `Interval` (27) are Wave C, so ~28% of the EN rules are gated behind both earlier waves. `HourMinute` is 26. Those three issues each carry a concrete suggested sub-split; `Holiday` carries the split note this issue already called for.

  ### Rule ownership is exclusive, and this is the rule

  **A rule is owned by the highest-wave variant it constructs.** `"tomorrow morning"` builds `Composed(Tomorrow, PartOfDay)`, so it is a Wave C `Composed` rule, not a Wave A `Tomorrow` rule. 33 rules construct more than one variant; without a single-owner rule they would be claimed by several slices at once, which is exactly the conflict the one-file-per-slice convention exists to prevent. Phase 1 (##{I["p1"]}) buckets fixture cases by the same rule, so the slice that owns a case is the slice that owns the rule that produced it.

  All 221 rules are assigned, each to exactly one slice.

  ### The slice table

  | Slice | Wave | EN rules | Phase 2 | Phase 3 audit |
  |---|---|---|---|---|
  #{tbl}

  ### Conventions carried into every slice issue

  Each Phase 2 issue names the four files its agent creates and states that everything else — spine, base classes, fixture format — is frozen ##{I["p0"]} output, with spine gaps filed as follow-ups rather than edited in place. Each repeats the corpus-TDD constraint (do not read the Rust rule implementations; pattern strings excepted, take them from PR #162's `docs/spike/duckling_patterns.json`) and the regex dialect notes. Each Phase 3 issue inverts that: it names the exact `en.rs` line numbers and `mod.rs` references to read, and carries the three-outcome table for a new case.
MD

File.write("/tmp/c163.md", body)
sh("gh", "issue", "comment", "163", "-R", REPO, "-F", "/tmp/c163.md")
puts "commented"
