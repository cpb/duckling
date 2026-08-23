# stage120 — assign rule ownership

32 rules construct more than one `TimeForm` variant, so "which slice owns this
rule" has no natural answer and needs a stated tiebreak.

**A rule is owned by the highest-wave variant it constructs.**

`"tomorrow morning"` builds `Composed(Tomorrow, PartOfDay)`. `Composed` is
Wave C, `Tomorrow` and `PartOfDay` are Wave A, so the rule belongs to the
Wave C `Composed` slice. This guarantees a rule is never assigned to a slice
that would have to be written before its dependencies exist.

The stage asserts that every rule ends up owned exactly once and fails loudly
otherwise — a duplicate would mean two parallel agents editing one file, which
is the single failure the whole one-file-per-slice convention exists to stop.

## The consequence worth knowing

Ownership by outermost constructor concentrates rules in the late waves:
`Composed` 34 and `Interval` 27 are both Wave C, so about 28% of the EN rules
sit behind both earlier waves. Their issues carry suggested sub-splits.

Output: `out/ownership.json` — 38 owners, 221 rules.
