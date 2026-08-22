require_relative "gh"
require "json"
I = ids; A1 = I.fetch("a1")
cov = JSON.parse(File.read(File.join(__dir__, "coverage.json")), symbolize_names: true)
dead = cov.select { |r| r[:dead] && !r[:any_error] }
tbl = dead.map { |r|
  pats = r[:results].map { |x| "`#{x[:pattern].gsub("|", "\\|")}`" }.join("<br>")
  "| `#{r[:name].gsub("|", "\\|")}` | #{r[:dimension]} | #{r[:line]} | #{pats} |"
}.join("\n")

b2 = create(
  title: "Corpus: add cases for the 11 rules no corpus case reaches at all",
  labels: %w[corpus],
  body: <<~MD
    Parent: #163 · **Corpus stage.** Blocked by ##{A1}. Runs in parallel with the other corpus tickets.

    ## What this is

    Of the 276 EN rules in duckling 0.4.0, **11 have no corpus text matching their pattern at all** — not a thin branch, the whole rule. These are shipped, reachable rules with zero coverage in #255.

    | Rule | Dim | en.rs | Pattern |
    |---|---|---|---|
    #{tbl}

    ## Worth noting about several of these

    - **`fortnight`, `quarter of an hour`, `three-quarters of an hour`** — three duration rules with no coverage whatsoever. `duration` is a Wave A dependency slice (##{I["dims"]["duration"]}) that most of Wave B consumes.
    - **`date MM DD YYYY` and `date DD MM YYYY`** share one pattern and disambiguate by locale convention. Untested, that ambiguity is invisible to a porting agent — and getting it backwards silently swaps months and days.
    - **`iso8601 datetime with T separator`** is an explicit en-extension over upstream, and nothing exercises it.
    - **`half to|till|before <hour-of-day>`** — the whole "half to five" construction.
    - **`<time-of-day> sharp|exactly`** — also appears in ##{I["b1"]}'s branch list; cover it once, in whichever ticket gets there first.

    ## Definition of done

    - [ ] At least one corpus case per rule above, in `test/fixtures/wafer_corpus_local/` (never a single shared file)
    - [ ] For `date MM DD YYYY` versus `date DD MM YYYY`, cases that actually **discriminate** the two — a date where the two readings differ, not one where they coincide
    - [ ] Every expectation captured from the native backend and verified by hand to be correct
    - [ ] A rule that turns out to be genuinely unreachable is recorded as such with the reason, rather than left silently uncovered
    - [ ] Anything behaving unexpectedly is filed upstream against wafer-inc/duckling rather than pinned silently
    - [ ] `rake corpus:generate` clean, staleness test passing, full suite green
  MD
)
record("b2", b2); link(163, b2); puts "B2 dead rules = ##{b2}"

a2 = create(
  title: "Corpus: cover with_latent: and the 24 call sites #255 excluded",
  labels: %w[corpus test-first],
  body: <<~MD
    Parent: #163 · **Corpus stage.** Blocked by ##{A1}. The largest of the corpus tickets — this one changes the pipeline, not just the fixtures.

    ## The gap

    `with_latent:` is a documented parameter of the public `Duckling.parse` API, and **the 1,656-case corpus exercises none of it.** Measured against the fixture: zero cases carry a latent flag.

    Meanwhile `src/dimensions/time/en.rs` has **12 rules whose names end in `(latent)`** and **15 `TimeData::latent(...)` construction sites**:

    ```
    morning (latent)     afternoon (latent)   evening (latent)     night (latent)
    lunch (latent)       hhmm (latent)        H a/p (latent)       time-of-day (latent)
    year (latent)        <latent-time> <time> compose
    <year> (latent) - <year> (latent) (interval)
    <part-of-day> <latent-time-of-day> (latent)
    ```

    On top of that, `latent` is the single most-mutated field in the modifier slice (##{I["phase2"]["Modifiers"]}) — 21 of its 23 rules promote a latent token to a real one. A Ruby backend can get latency wrong in both directions (emitting entities that should be suppressed, or suppressing ones that should surface) and pass every fixture row #255 produces.

    ## #255's own excluded list

    #255 leaves out 24 commented-out call sites in `time_corpus.rs`, for two reasons it states plainly:

    - **22 need `with_latent`**, which no upstream checker passes
    - **2 (`diffCorpus`) need a third reference time**, 2013-02-15 04:30 −02:00

    Those 24 are the natural seed for this ticket, but they are the floor, not the ceiling — 12 latent-producing rules deserve more than 22 cases between them.

    ## Scope

    - [ ] A checker in `test/support/wafer_matchers.rb` that passes `with_latent: true`, following the existing matcher conventions exactly (`.any?` over entities, 0.01 float tolerance, wall-clock comparison)
    - [ ] The fixture schema carries the flag, and `script/generate_corpus_tests.rb` renders it — this is a pipeline change, so `test/wafer_corpus_generation_test.rb` must still detect a stale tree
    - [ ] A third reference time (2013-02-15 04:30 −02:00) alongside the existing default / saturday / friday_evening contexts
    - [ ] The 22 `with_latent` call sites enabled; the 2 `diffCorpus` cases enabled
    - [ ] Coverage for each of the 12 latent-producing rules, in **both** directions: the latent reading suppressed by default, and surfaced under `with_latent: true`
    - [ ] `docs/wafer-corpus.md` updated with the new checker, the flag, and the fourth reference time
    - [ ] Cases land in `test/fixtures/wafer_corpus_local/`, not the extracted fixture — `corpus:refresh` would wipe them

    ## Why this one is `test-first`

    The checker is new machinery, not a data addition. Write it against a case you know the native backend's answer to before enabling the 24, so a broken checker fails loudly instead of quietly passing 24 cases it is not really testing.
  MD
)
record("a2", a2); link(163, a2); puts "A2 with_latent = ##{a2}"
