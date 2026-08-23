# stage160 — join gaps to slices

Attributes every gap from stage140 and stage150 to the slice that owns the
rule, so each slice issue carries its own findings and no two agents chase the
same one.

**16 of 42 slices have a detected gap.** The concentration:

| Slice | unreached | branches | opaque |
|---|---|---|---|
| Modifiers | 2 | 45 | 0 |
| Interval | 0 | 43 | 0 |
| Composed | 1 | 0 | 10 |
| ordinal | 0 | 24 | 0 |
| numeral | 0 | 11 | 3 |
| DateMDY | 2 | 7 | 4 |

`severity` in the output ranks where to look first. Its weights — unreached ×3,
branch ×1, opaque ×4 — are a judgement call, not a measurement, and exist only
for ordering.

Issue numbers are filled in from `../../issue-ledger.json` when it exists, so
this stage is useful before any issue is created and more useful after.

## The 26 "clean" slices are not covered slices

They are slices this technique found nothing in. Opaque rules are invisible to
it, and a matched branch is not a fired branch. Read
`stage000-shared/partials/_sweep_caveat.md.erb` — every audit issue says so.

Output: `out/gaps_by_slice.json`.
