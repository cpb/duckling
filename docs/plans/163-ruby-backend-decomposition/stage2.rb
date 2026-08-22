require_relative "gh"
P0 = ids.fetch("p0")

rank = create(
  title: "Ruby backend — port the ranking layer and load the upstream trained classifiers",
  labels: %w[ruby-backend phase-0 pr-train test-first],
  body: <<~MD
    Parent: #163 · **Phase 0 · blocked by ##{P0} · runs in parallel with Phase 1 and Wave A.**

    ## Scope

    Port `src/ranking/mod.rs` (398 lines) and load the six trained Naive-Bayes classifier JSONs as-is. `en_xx.json` is 167 KB; the six total 468 KB.

    Ranking is **independent of the rules** — it scores whatever the engine produced. That is why it is broken out of ##{P0} rather than bundled with the spine: once ##{P0}'s base classes land, this can run alongside the whole of Wave A.

    ## Why it is not optional

    Without ranking, overlapping-rule cases resolve differently and time parity is unreachable. It is not a tie-break nicety; it is what decides which of several competing parses wins.

    ## Definition of done

    - [ ] `src/ranking/mod.rs`'s scoring ported to Ruby
    - [ ] The six upstream trained classifier JSONs load as-is — **not retrained**; `ranking/train.rs` is explicitly out of scope per #163
    - [ ] The classifier data is vendored with its BSD-3-Clause notice preserved, the same way the corpus fixture is
    - [ ] A test pins the ranker's output ordering on a case with overlapping rule matches, against the native backend's ordering
    - [ ] Loading 468 KB of JSON is accounted for in the memory story — record the `require`-time delta so Phase 4 can attribute it

    ## Files you own

    - `lib/duckling/ruby/ranking.rb` (or a small directory under it)
    - the vendored classifier JSONs
    - `test/ruby_backend/ranking_test.rb`

    Do not edit the spine, the base classes, or the fixture format — those are frozen ##{P0} output.
  MD
)
record("rank", rank); link(163, rank); puts "rank = ##{rank}"

p1 = create(
  title: "Ruby backend Phase 1 — fixture capture script, bucketed by slice",
  labels: %w[ruby-backend phase-1 pr-train],
  body: <<~MD
    Parent: #163 · **Phase 1 — serial, one agent, blocked by ##{P0}, blocks all of Phase 2.**

    ## Scope

    One script that replays every EN corpus case from #157 through the **native** backend and writes per-slice fixture files.

    Each fixture row records: the input text, the reference context, and the resolved entity output from the public `Duckling.parse` — decision 3 of #163, per-case golden fixtures captured from the public API. **No crate instrumentation.**

    ## Definition of done

    - [ ] Script in tree, regeneratable, keyed to the pinned crate version (duckling 0.4.0) and to #157's corpus sha — both recorded in the output
    - [ ] Writes one file per slice: `test/fixtures/ruby_backend/<slice>.json`, matching ##{P0}'s fixture format exactly
    - [ ] Bucketing follows the slice manifest — the 37 `TimeForm` variants, the modifier slice, and the four dependency dimensions
    - [ ] **Surfaces, rather than silently drops, any case that maps to no slice or to more than one.** This is the whole reason Phase 1 is serial and runs before the fan-out: a case with no home discovered during Phase 2 costs an agent's whole run
    - [ ] Reports per-slice case counts, so the fan-out can be sized before it starts
    - [ ] BSD-3-Clause notice preserved on the derived data

    ## The bucketing problem

    A corpus case exercises whatever the parse produced, which is often a composite. `"tomorrow morning"` builds `Composed(Tomorrow, PartOfDay)` — it belongs to the `Composed` slice, not to `Tomorrow`. Bucket by the **outermost** `TimeForm` the native backend resolved, so the slice that owns the case is the slice that owns the rule that produced it. That is the same attribution rule the rule manifest uses (see any Phase 2 slice issue).

    ## Note on ordering

    #163 branches off #157, which owns the corpus extractor and the checked-in fixture. As of writing #157 is unstarted and has no branch. There is no work here until it exists.
  MD
)
record("p1", p1); link(163, p1); puts "p1 = ##{p1}"
