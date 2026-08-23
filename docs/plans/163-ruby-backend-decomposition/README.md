# Decomposing #163 into subtasks

[#163](https://github.com/cpb/duckling/issues/163) proposes a pure-Ruby Onigmo
parse backend and sketches a map-reduce shape for building it: 37 `TimeForm`
variants, 221 EN rules, three waves. This directory is the pipeline that turned
that sketch into 95 issues, and the derivation behind every number in them.

It is kept in tree because the numbers are load-bearing. They decide which
slice owns which file, and re-deriving them by hand is how two of 42 parallel
agents end up editing one file.

## Start here

```
plan.yml                 what this pipeline is pointed at — repo, crate, corpus, labels
issue-ledger.json        pipeline key -> live issue number. The only real state.

stage000-shared/         libraries and ERB partials every stage uses
stage100-analysis/       read-only derivation from the crate and the corpus
stage200-issue-ops/      turns that into GitHub issues
loop-prompt.md           the /loop prompt that drives the resulting tree
```

Each stage directory has its own `readme.md` explaining what it answers and
why it works the way it does. Issue prose lives in `*.md.erb` beside the
runner that renders it, so changing what an issue *says* never means reading
Ruby.

## Running it

Analysis is read-only and safe:

```sh
for s in stage100-analysis/stage1*/; do ruby "$s/run.rb"; done
```

Issue-ops writes. Preview first — there is no undo for 95 issues:

```sh
DRY_RUN=1 ruby stage200-issue-ops/stage220-create-timeform-slices/run.rb
```

See `stage200-issue-ops/readme.md` for the full order and the idempotency
rules.

## What the derivation found

**221 EN time rules across 37 `TimeForm` variants — and the two do not
partition together.** 32 rules construct more than one variant, so ownership
needs a stated tiebreak. The one used throughout: *a rule is owned by the
highest-wave variant it constructs.* `"tomorrow morning"` builds
`Composed(Tomorrow, PartOfDay)`, so it is a Wave C `Composed` rule. All 221
rules land in exactly one slice, asserted by `stage120`.

**23 rules construct no `TimeForm` at all.** They clone a `TimeData` and mutate
`latent`, `early_late`, `open_interval_direction`, `timezone` or `direction`.
#163's 37-variant plan had no home for them; they became a 38th slice.

**Rule mass is lopsided.** `Composed` 34, `Interval` 27, `HourMinute` 27 — and
the first two are Wave C, so about 28% of the rules sit behind both earlier
waves. Those issues carry suggested sub-splits.

**PR #255's corpus is strong but has measurable holes.** Every regex from all
276 EN rules, translated to Ruby and tested against all 1,662 corpus texts:

| Gap class | Size |
|---|---|
| Unexercised literal alternation branches | 140 across 23 rules |
| Rules no corpus text reaches at all | 11 |
| `with_latent:` coverage | zero, against 12 latent-producing rules |
| Rules with no regex item — unmeasurable this way | 27 |

Concretely: the corpus contains **no timezone abbreviation at all**, never says
**June, November or December**, never exercises **spring, fall or autumn**, and
stops at **`fifth`** for ordinal words.

That is what moved the gap audit ahead of the port. A gap found before the port
never reaches the porting agent; the same gap found after means re-opening a
merged slice.

**All 276 patterns translated to Ruby with zero errors**, needing only
`(?P<` → `(?<`. #163's Notes reserve a regex-compatibility harness "if it turns
out to be needed" — on this evidence, it is not.

## The caveat that governs all of it

A branch matching no corpus text is definitely unexercised. **The converse does
not hold**: a branch that appears in some text may still never fire, because
another rule can win the span.

So every count here is a **lower bound**, and the 26 slices with no detected
gap are not thereby covered. The 27 rules whose patterns are pure
`predicate`/`dim` composition are invisible to the technique entirely. Proving
coverage needs a person reading the source, which is what the 42 audit issues
commission.

## Upstream divergences

An audit that finds the native backend disagreeing with the Rust opens an
`upstream-divergence` issue **on this repo**, never against
`wafer-inc/duckling`. See "Upstream divergences" in AGENTS.md for why, and for
what such an issue records.

The sharp edge: the corpus becomes the specification a reimplementation is
written against, so a silently pinned divergence stops being an upstream bug
and becomes a required behaviour of this gem.

## Reusing this for another issue

`plan.yml` is the only file that names a repo, an issue, a crate or a corpus.
Point it somewhere else and the analysis stages work unchanged. The issue-ops
templates are specific to #163's phase structure and would be rewritten — they
are the deliverable, not the framework.
