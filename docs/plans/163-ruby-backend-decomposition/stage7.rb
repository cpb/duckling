require_relative "gh"
require "json"
I = ids

a1 = create(
  title: "Corpus: split local additions into a globbed directory so audits can run in parallel",
  labels: %w[corpus pr-train],
  body: <<~MD
    Parent: #163 · **Corpus stage — serial, blocks every parallel corpus ticket.** Follows #255 (#157).

    ## Why

    `script/generate_corpus_tests.rb` hardcodes its inputs:

    ```ruby
    EXTRACTED_FIXTURE = "wafer_corpus.json"
    FIXTURES = {
      EXTRACTED_FIXTURE => nil,
      "wafer_corpus_local.json" => "local"
    }
    ```

    One local file. The corpus-audit stage puts **42 agents** to work adding cases at the same time, and every one of them would append to `test/fixtures/wafer_corpus_local.json`. That is a guaranteed 42-way merge conflict on a single JSON array.

    This is the same problem #163 already solved for the Ruby backend's source layout, and it takes the same answer: **no central file, glob instead.**

    ## Scope

    - [ ] Replace the single `wafer_corpus_local.json` with a directory: `test/fixtures/wafer_corpus_local/*.json`, each file the same case schema
    - [ ] `FIXTURES` becomes a glob rather than a literal hash; ordering must be deterministic (sort by filename) so the generated tree stays byte-stable and `test/wafer_corpus_generation_test.rb` keeps working
    - [ ] Move the existing 6 `by <named day>` deadline cases to `test/fixtures/wafer_corpus_local/by_deadline.json` unchanged — same cases, same generated output
    - [ ] The generated test tree is unchanged by this refactor except for file naming, and the staleness test proves it
    - [ ] `rake corpus:refresh` still rewrites only the extracted fixture and never touches the local directory
    - [ ] `docs/wafer-corpus.md` updated: how to add a local case, and the one-file-per-contributor rule
    - [ ] Naming convention documented and enforced by review: one file per slice, named for the slice, so no two audit agents collide

    ## Not in scope

    Adding cases. This ticket only makes it possible to add them in parallel.
  MD
)
record("a1", a1); link(163, a1); puts "A1 glob-split = ##{a1}"
