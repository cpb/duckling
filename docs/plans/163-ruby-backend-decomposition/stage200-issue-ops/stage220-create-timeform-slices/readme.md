# stage220 — create TimeForm slices

38 issues: one per `TimeForm` variant, plus the modifier slice.

| Template | Renders |
|---|---|
| `time_form_slice.md.erb` | the 37 variant slices |
| `modifier_slice.md.erb` | the 23 rules that construct no variant at all |
| `notes.yml` | wave descriptions and per-slice sizing warnings |

## What is computed versus written

Everything factual comes from `stage130`'s manifest: the wave, the Rust enum
excerpt, the resolver reference count, the owned rule list. Nothing in the
template restates a number a human would have to keep in sync.

`notes.yml` holds only what cannot be derived — how to describe a wave, and
which four slices are big or risky enough to warn the assignee about
(`Composed` 34 rules, `Interval` 27 and highest-risk, `HourMinute` 27,
`Holiday` for its calendar arithmetic).

Sizing notes are YAML **literal** blocks, not folded. They contain blockquotes,
and folding joins the lines into one paragraph — which is exactly what went
wrong the first time.

## The modifier slice

#163's plan has 37 variants and 221 rules, and assumes the two partition
together. They do not: 23 rules clone a `TimeData` and mutate a flag without
constructing anything. They get their own issue, their own rule table keyed by
which field each mutates, and no `time/forms/` file — there is no variant, so
there is no resolver.
