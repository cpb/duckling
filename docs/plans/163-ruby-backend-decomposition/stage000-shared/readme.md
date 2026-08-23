# stage000-shared

Everything more than one stage needs. Nothing here talks to GitHub or the
crate on its own — stages do that, using these.

## Libraries

| File | Responsibility |
|---|---|
| `config.rb` | Loads `../plan.yml`, resolves the crate path from its glob, reads the corpus fixtures (falling back to PR #255's branch while it is unmerged). Every stage starts here, so no stage hardcodes a repo, an issue number or a path. |
| `crate.rb` | Parses the pinned Rust crate: rules with their patterns, what each production constructs, which `TimeData` fields it mutates, and the `TimeForm` enum with per-variant source excerpts. Also `RustRegex.to_ruby`. |
| `slices.rb` | The pipeline's unit of work. Turns rules and variants into slices and applies the ownership tiebreak. |
| `ledger.rb` | Maps a pipeline key (`"slice:Interval"`) to the issue number it became. This is the entire idempotency story — see below. |
| `github.rb` | Issue create/edit/link/comment, all idempotent through the ledger. |
| `renderer.rb` | Renders a stage's ERB with an explicit set of locals and nothing else. |

## Two things worth understanding before editing

**Ownership is a tiebreak, not a lookup.** 33 of the 221 EN rules construct
more than one `TimeForm` variant, so "which slice owns this rule" has no
natural answer. `SliceSet#owner_of` picks the **highest-wave** variant a rule
constructs: `"tomorrow morning"` builds `Composed(Tomorrow, PartOfDay)`, so it
is a Wave C `Composed` rule, not a Wave A `Tomorrow` one. Change that rule and
slices start claiming each other's files, which is the one failure the
one-file-per-slice convention exists to prevent.

**Creation is idempotent, and only because of the ledger.** `GitHub.upsert`
keys on a pipeline-chosen name, not a title. If the ledger has a number it
edits; if not it creates and records. Delete `issue-ledger.json` and the next
run mints 95 duplicates, and nothing in the GitHub API would object.

## Partials

`partials/_*.md.erb` are the blocks that appear in many issue bodies. They take
locals, same as any template, and are reached with `partial "name"` from
inside a stage template.

| Partial | Appears in |
|---|---|
| `_constraints` | every port issue — the six constraints from #163 |
| `_regex_dialect_notes` | every port issue that writes patterns |
| `_corpus_tdd_rule` | every Phase 2 slice — the do-not-read-the-Rust rule |
| `_files_you_own` | every Phase 2 slice — the four files, and what is frozen |
| `_two_outcomes` | every corpus audit — what to do when native surprises you |
| `_sweep_caveat` | every corpus audit — lower bound, not a clean bill of health |
| `_upstream_divergence` | everything that can find a divergence |
