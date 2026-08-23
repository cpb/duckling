# stage100-analysis

Read-only derivation. Nothing here touches GitHub; every stage reads the
pinned crate and PR #255's corpus and writes one JSON to its own `out/`.

Run in order — each stage reads the one before it:

```sh
for s in stage1*/; do ruby "$s/run.rb"; done
```

| Stage | Answers | Writes |
|---|---|---|
| `stage110-attribute-rules-to-variants` | what does each rule construct or mutate? | `rule_attribution.json` |
| `stage120-assign-rule-ownership` | which single slice owns each rule? | `ownership.json` |
| `stage130-build-slice-manifest` | what is each slice: wave, excerpt, rules? | `slices.json` |
| `stage140-measure-corpus-coverage` | which rules does the corpus never reach? | `coverage.json` |
| `stage150-find-unexercised-branches` | which alternation paths does it never walk? | `unexercised_branches.json` |
| `stage160-join-gaps-to-slices` | which slice owns each gap? | `gaps_by_slice.json` |

## What it found

221 EN time rules across 37 `TimeForm` variants, plus 55 rules in four
dependency dimensions. **32 rules construct more than one variant**, which is
why ownership needs a tiebreak, and **23 construct none at all**, which is the
modifier slice #163's plan had no home for.

Against PR #255's 1,662 corpus texts: **11 rules the corpus never reaches**,
**140 unexercised literal alternation branches** across 23 rules, and **27
rules the sweep cannot measure at all** because their patterns are pure
`predicate`/`dim` composition.

**0 of 276 patterns failed to translate to Ruby**, needing only
`(?P<` → `(?<`. That is decision 5's risk, measured: the regex-compatibility
harness #163 holds in reserve is probably not needed.

## The caveat that matters

A branch matching no corpus text is definitely unexercised. The converse does
not hold — a branch that appears in some text may still never fire, because
another rule can win the span. Every count here is a **lower bound**, and the
26 slices with no detected gap are not thereby covered. Proving coverage needs
either instrumentation or a person reading the source, which is what
`stage250-create-corpus-audits` commissions.
