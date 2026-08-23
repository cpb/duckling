# stage150 — find unexercised branches

A rule the corpus reaches can still have paths it never walks.
`(mon|tue|wed|thu|fri|sat|sun)` is one pattern and seven branches, and
stage140 counts it covered if any one of them appears.

This stage splits every pattern into its alternation branches — inside each
group and across the whole — keeps the ones that are plain literals, and
reports those no corpus text contains.

**140 unexercised branches across 23 rules.** The largest:

- **21 timezone abbreviations** across four rules. The corpus contains no
  timezone abbreviation at all, and `timezone` is a `TimeData` field the port
  must carry.
- **24 ordinal words** — the corpus stops at `fifth`.
- **5 month names** — it never says June, November or December.
- **3 season words** — only `summer` and `winter` appear.

## Why only literal branches

A branch that is itself a regex (`\d{1,2}`, `[0-5]\d`) tells you nothing by
being absent from the corpus as a string. Restricting to literals keeps every
reported item actionable: each one is a word you can put in a test case.

Output: `out/unexercised_branches.json`.
