# stage140 — measure corpus coverage

Translate every rule regex to Ruby and test it against every corpus text.
Two questions at once.

**Does the dialect translate?** Rust `regex` and Onigmo differ in a lot on
paper — no backreferences or lookaround in Rust, different Unicode class
semantics, different alternation order. In practice, over all 276 EN rules:
**276 translated, 0 errors**, needing only `(?P<` → `(?<`. #163 reserves a
compatibility harness "if it turns out to be needed"; on this evidence it is
not.

**Which rules does the corpus never reach?** 11 have no corpus text matching
any of their patterns. Not a thin branch — the whole rule, uncovered.

A third number falls out: **27 rules have no regex item at all**. Their
patterns are pure `predicate`/`dim` composition (`intersect`,
`<month> <year>`, `<ordinal> <month>`), so there is nothing to test and this
technique cannot see them. They are the audit stage's primary target.

Output: `out/coverage.json` — 276 entries.
