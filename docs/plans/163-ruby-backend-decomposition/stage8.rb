require_relative "gh"
require "json"
I = ids
A1 = I.fetch("a1")
db = JSON.parse(File.read(File.join(__dir__, "dead_branches.json")), symbolize_names: true)

tbl = db.sort_by { |r| -r[:dead_branches].size }.map { |r|
  "| `#{r[:name].gsub("|", "\\|")}` | #{r[:dimension]} | #{r[:line]} | #{r[:dead_branches].size} | #{r[:dead_branches].join(" · ")} |"
}.join("\n")

b1 = create(
  title: "Corpus: add cases for 140 unexercised regex alternation branches",
  labels: %w[corpus],
  body: <<~MD
    Parent: #163 · **Corpus stage.** Blocked by ##{A1} (needs the globbed local-fixture directory). Runs in parallel with the other corpus tickets.

    ## What this is

    Every regex from all 276 EN rules of duckling 0.4.0 was translated to Ruby and its literal alternation branches tested against all 1,662 corpus texts from #255. **140 literal branches across 23 rules match no corpus case.** They are listed in full below, so this ticket is mechanical: one case per branch, appended to the local fixture directory.

    Each is a real path through a shipped rule that #255's corpus never walks. Left as-is, 42 Phase 2 agents port against a spec that does not mention them, and the Phase 2 fixtures cannot catch a wrong port.

    ## Highlights

    - **21 timezone abbreviations** — `utc`, `edt`, `cest`, `jst`, `aedt`, `nzdt` and 15 more, unexercised across four rules. The corpus contains **no timezone abbreviation at all**, and `timezone` is a `TimeData` field the Ruby port has to carry.
    - **24 ordinal words** — the corpus stops at `fifth`. `sixth` through `nineteenth`, and every `twentieth`…`ninetieth`, are untested.
    - **5 month names** — the corpus never says **June, November or December** (nor `jun`/`nov`). Verified directly against the fixture.
    - **3 season words** — `spring`, `fall` and `autumn` are untested; only `summer` and `winter` appear.
    - **11 numeral words** — including `thirteen`, `eighty`, `ninety`, `trillion`, and the zero-synonyms `none` and `zilch`.

    ## The full list

    | Rule | Dim | en.rs | Missing | Branches |
    |---|---|---|---|---|
    #{tbl}

    ## Definition of done

    - [ ] One corpus case per branch above, in `test/fixtures/wafer_corpus_local/` (one file per dimension or per rule group, never one shared file)
    - [ ] Every case's expectation is captured from the **native** backend and verified by hand to be correct, not merely recorded — a wrong expectation pinned as golden is worse than no case
    - [ ] Any case that does **not** behave as expected is an upstream finding: record it and file it against wafer-inc/duckling rather than pinning the surprising behaviour silently
    - [ ] `rake corpus:generate` regenerates cleanly; the staleness test passes
    - [ ] Full suite green

    ## Method caveat, carried from the analysis

    A branch matching no corpus text is definitely unexercised. The converse does not hold: a branch that *does* appear in some text may still never fire, because another rule can win the span. This list is a **lower bound** — closing it does not mean the rules are fully covered. That is what the corpus-audit stage is for.
  MD
)
record("b1", b1); link(163, b1); puts "B1 branches = ##{b1}"
