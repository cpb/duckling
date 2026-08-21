# The wafer-inc/duckling EN corpus

`test/wafer/` replays the wrapped crate's own EN test corpora through
`Duckling.parse`. This is end-to-end coverage of the tagged `:value` shapes
across all 13 dimensions, from one source that no one here wrote by hand.

## The pipeline

Two stages, split at the network boundary:

```
wafer-inc/duckling tests/*_corpus.rs
  │  script/extract_wafer_corpus.rb          needs network — rake corpus:refresh
  ▼
test/fixtures/wafer_corpus.json + wafer_corpus_local.json
  │  script/generate_corpus_tests.rb         offline — rake corpus:generate
  │  script/templates/corpus_test.rb.erb
  ▼
test/wafer/<dimension>/<check>_test.rb       26 files, committed
```

`corpus:refresh` runs `corpus:generate` as its last step, so one command
updates everything. The second stage stays offline and deterministic on
purpose: it is what lets `test/wafer_corpus_generation_test.rb` detect a stale
tree during an ordinary `rake test`, with no network and no subprocess.

**Everything under `test/wafer/` is generated. Do not edit it by hand** — the
staleness test will fail, and the next `corpus:generate` overwrites the change.
Fix a wrong expectation in the fixture, or in the matcher it calls.

## What is in the fixture

`script/extract_wafer_corpus.rb` reads the `tests/*_corpus.rs` files of a
[wafer-inc/duckling](https://github.com/wafer-inc/duckling) checkout. Those
files are a Rust port of facebook/duckling's Haskell corpora. Each file holds
`#[test] fn` groups, and each group calls one or more `check_*` helpers with a
text and its expected value.

The extractor records one case per `check_*` call site:

```json
{"file":"time_corpus.rs","line":210,"group":"test_time_today","check":"time_naive","text":"today","expected":{"value":[2013,2,12,0,0,0],"grain":"day"}}
```

`test/fixtures/wafer_corpus.json` holds those cases, 1,656 of them, plus the
upstream commit they came from. The file is generated. Do not edit it.

`test/fixtures/wafer_corpus_local.json` holds hand-written cases in the same
schema. The refresh task never writes this file. It currently covers `by
<named day>` deadlines, which upstream does not (see "Deadline synthesis"
below).

Two kinds of upstream case are left out:

- Call sites behind a `//`. `time_corpus.rs` keeps 24 of them, for two
  different reasons: 22 need `with_latent`, which no upstream checker passes,
  and 2 (`diffCorpus`) need a third reference time, 2013-02-15 04:30 −02:00.
- `tests/pending_corpus.rs`. Upstream knows those fail.

Both fixtures are BSD-3-Clause derived data. See `NOTICES`.

## Refreshing the fixture

```
bundle exec rake corpus:refresh              # upstream default branch HEAD
bundle exec rake 'corpus:refresh[c96b068]'   # a named ref
```

The task clones into `tmp/wafer-duckling`, rewrites
`test/fixtures/wafer_corpus.json` including the `upstream.sha` field, then
regenerates `test/wafer/`. Read the diff before committing: a refresh that
changes an expected value is upstream changing its mind about a phrase, and
each such change needs a decision, not a rubber stamp. The generated tests
make that diff legible — the changed expectation shows up as a changed
assertion, next to the group it belongs to.

After editing `wafer_corpus_local.json` by hand, run `rake corpus:generate`
alone. It needs no network.

## The generated tests

One file per (dimension, check), named for the check with a leading dimension
prefix stripped — `time_naive` becomes `test/wafer/time/naive_test.rb`. The 659
upstream groups never mix check kinds, so no `#[test] fn` is ever split across
two files. Each group becomes one method carrying the same name upstream gave
it, with one assertion per `check_*` call:

```ruby
# time_corpus.rs:230
def test_time_today
  assert_time_naive "today", [2013, 2, 12, 0, 0, 0], :day
  assert_time_naive "at this time", [2013, 2, 12, 0, 0, 0], :day
end
```

Class names are flat (`WaferTimeNaiveTest`), not nested. A `Wafer::Time`
module would shadow `::Time` inside the very files whose subject is time
values.

Real `def test_*` lines are the point of generating rather than building the
methods at load time: `bin/test test/wafer/time/naive_test.rb:14` resolves to
`test_time_today` and runs exactly it, the names are greppable, and a failure
points at the line that failed. Assertions are fail-fast within a method, as
upstream's Rust `assert!` is, so each carries the text, the expectation, and
the entities actually returned.

## Matcher semantics

`test/support/wafer_matchers.rb` mirrors the upstream Rust checkers. Three
rules are easy to get wrong, and all three were measured:

- **A measurement `Interval` matches when either bound matches.** The Rust
  checkers say so in a comment: "matching original test behavior". A matcher
  that accepts only the `Value` variant reports 93 false failures on interval
  phrasings such as "between 10 and 20 dollars".
- **An interval's expected grain has to appear on one leg, not on both.**
- **Floats compare with a 0.01 tolerance**, and datetimes compare as
  wall-clock components. Upstream holds a `NaiveDateTime` for a `Naive` leaf
  and reads an `Instant` leaf through `naive_local()`. Both are that leaf's
  own wall clock, so the runner compares
  `[year, month, day, hour, min, sec]`.

Every case is `.any?` over the entities the parse returned, again mirroring
upstream: the corpus states that a reading is present, not that it is the
only one.

## Reference times

The time corpora anchor every relative expression on Tuesday 2013-02-12
04:30:00 −02:00. Two groups override it, because weekend resolution turns on
whether the reference moment is already inside a weekend:

| Context | Reference time |
|---|---|
| (default) | 2013-02-12 04:30 −02:00, a Tuesday |
| `saturday` | 2013-02-09 10:00 −02:00 |
| `friday_evening` | 2013-02-08 20:00 −02:00 |

The fixture names the context; the runner holds the times, because they live
in Rust helper functions the extractor does not evaluate.

## Deadline synthesis

The crate's `by ` rule builds a *closed* interval `[now, named]`
(`TimeForm::Interval(Now, t)` in `src/dimensions/time/en.rs`). All 13 upstream
`"by …"` cases expect `from` to equal the reference instant exactly.

So "both bounds present" is not the same as "both bounds stated in the text".
Consumer code that wants to tell a deadline from a stated range has to compare
`from` against the reference time it passed in.

Upstream covers `by <clock time>` and `by <end of period>` only. The local
fixture adds `by <named day>` — `"by Friday"`, `"by Friday July 3, 2026"`,
`"by the 15th"` — where the `to` bound is a `Naive` calendar day at `:second`
grain.

## Cost

1,662 short-string parses, about 1.2 seconds. The suite runs them under the
normal `rake test` task.
