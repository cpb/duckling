# Decomposing #163 into subtasks

How [#163](https://github.com/cpb/duckling/issues/163) — the pure-Ruby Onigmo
parse backend — was broken into 95 issues, and the derivation behind the
slicing. Everything here was computed from the pinned crate (`duckling 0.4.0`)
and from PR #255's corpus, not restated from the issue text.

Kept in tree because the numbers are load-bearing: they decide which slice owns
which rule, and re-deriving them by hand is how two slices end up editing the
same file.

## Findings

**221 EN time rules, 37 `TimeForm` variants — but the two do not partition
together.** 33 rules construct more than one variant. Ownership needs an
explicit tiebreak, and the one used throughout is: *a rule is owned by the
highest-wave variant it constructs.* `"tomorrow morning"` builds
`Composed(Tomorrow, PartOfDay)`, so it is a Wave C `Composed` rule. All 221
rules land in exactly one slice.

**23 rules construct no `TimeForm` at all.** They clone a `TimeData` and mutate
`latent`, `early_late`, `open_interval_direction`, `timezone` or `direction`.
#163's 37-variant plan had no home for them; they became a 38th slice.

**Rule mass is lopsided.** `Composed` 34, `Interval` 27, `HourMinute` 26 — and
the first two are Wave C, so ~28% of the rules sit behind both earlier waves.

**PR #255's corpus is strong but has measurable holes.** Every regex from all
276 EN rules was translated to Ruby and tested against all 1,662 corpus texts:

| Gap class | Size |
|---|---|
| Unexercised literal alternation branches | 140 across 23 rules |
| Rules no corpus text reaches at all | 11 |
| `with_latent:` coverage | zero, against 12 latent-producing rules |
| Rules with no regex item (unmeasurable this way) | 27 |

Concretely: the corpus contains no timezone abbreviation at all, never says
June, November or December, never exercises spring, fall or autumn, and stops
at `fifth` for ordinal words.

**All 276 patterns translated to Ruby with zero errors**, needing only
`(?P<` → `(?<`. #163's Notes reserve a regex-compatibility harness "if it
turns out to be needed" — on this evidence it is not.

### Method caveat

A branch matching no corpus text is definitely unexercised. The converse does
not hold: a branch that appears in some text may still never fire, because
another rule can win the span. The counts above are **lower bounds**, and a
slice the sweep found clean is not a covered slice. The 27 rules whose patterns
are pure `predicate`/`dim` composition are invisible to the technique entirely
— which is why the 42-way corpus audit still runs.

## Layout

Flat on purpose: the scripts resolve their data via `__dir__`, so they stay
runnable exactly as they were run.

| File | What it does |
|---|---|
| `map3.rb` | attributes each EN rule to the `TimeForm` variants it constructs |
| `assign.rb` | applies the highest-wave-wins tiebreak, yielding `ownership.json` |
| `manifest.rb` | builds `slices.json` — per-slice variant excerpt, wave, rules |
| `coverage.rb` | translates every rule regex to Ruby, tests against the corpus |
| `branches.rb` | finds unexercised literal alternation branches |
| `join.rb` | joins gaps to slice tickets, yielding `gaps.json` |
| `gh.rb` | issue-creation helpers (create, sub-issue link, id lookup) |
| `stage1.rb` … `stage14.rb` | the issue creation and retargeting passes, in order |
| `comment.rb`, `fix204.rb` | the #163 index comment; one body correction |
| `loop-prompt.md` | the orchestration prompt for `/loop` |

Data: `slices.json`, `ownership.json`, `dead_branches.json`, `gaps.json`,
`created.json` (slice → issue number).

Not committed: the corpus fixtures (they belong to PR #255) and
`coverage.json` / `rule_map*.json` (large and regenerable).

## Regenerating

Needs the pinned crate unpacked in the Cargo registry and PR #255's fixtures
copied alongside the scripts as `wafer_corpus.json` / `wafer_corpus_local.json`.

```sh
C=~/.cargo/registry/src/index.crates.io-*/duckling-0.4.0
D=docs/plans/163-ruby-backend-decomposition
ruby $D/map3.rb     "$C" $D/rule_map3.json
ruby $D/assign.rb   $D/rule_map3.json $D/ownership.json
ruby $D/manifest.rb "$C" $D/ownership.json $D/slices.json
ruby $D/coverage.rb "$C" $D          # writes coverage.json
ruby $D/branches.rb "$C" $D          # writes dead_branches.json
ruby $D/join.rb     $D                # writes gaps.json
```

The `stage*.rb` scripts create and edit real GitHub issues. They are recorded
for provenance, not for re-running — a second run would duplicate all 95.

## Upstream divergences

An audit that finds the native backend disagreeing with the Rust opens an
`upstream-divergence` issue **on this repo**, never against
`wafer-inc/duckling`. See "Upstream divergences" in AGENTS.md for why, and for
what such an issue records. The corpus is the specification a reimplementation
is written against, so a silently pinned divergence becomes a required
behaviour of this gem.
