require_relative "gh"
require "json"
I = ids
P3 = I.fetch("phase3_parent")

ci = create(
  title: "Ruby backend Phase 4 — run the full corpus against both backends in CI",
  labels: %w[ruby-backend phase-4],
  body: <<~MD
    Parent: #163 · **Phase 4 — reduce.** Blocked by ##{P3}.

    ## Scope

    Wire both backends into CI, running #157's full EN corpus against each.

    The differential **is** the oracle (decision 1 of #163) — that only holds if both backends actually run on every PR. A Ruby backend that only runs when someone remembers to run it stops being a check on the native one within a release.

    ## Definition of done

    - [ ] The corpus runs against the native backend and the Ruby backend in one suite
    - [ ] #157's 1,034 EN time cases pass on the Ruby backend, with the same matcher semantics: `.any` over entities, 0.01 float tolerance, wall-clock component comparison, the corpus reference contexts (2013-02-12 04:30 −02:00 default; Saturday 2013-02-09 10:00; Friday-evening 2013-02-08 20:00)
    - [ ] The dependency-dimension cases pass on the Ruby backend: numeral 105, duration 83, ordinal 32
    - [ ] Both backends run in CI — see AGENTS.md's `.github/workflows/main.yml` section for which job gates a merge (`baseline`, hardcoded `name: "Ruby 3.3.6"`) versus which gate a release
    - [ ] **The Ruby backend leg proves the no-Rust claim**: at least one CI leg loads and parses on the Ruby backend with no native extension built
    - [ ] Runtime is accounted for — the corpus is ~1,700 short-string parses per backend
    - [ ] AGENTS.md updated in the same PR (its "Keeping this file current" section makes this mandatory for CI and directory-layout changes)
  MD
)
link(163, ci); puts "ci -> ##{ci}"

meas = create(
  title: "Ruby backend Phase 4 — measure memory and throughput with PR #162's harness",
  labels: %w[ruby-backend phase-4],
  body: <<~MD
    Parent: #163 · **Phase 4 — reduce.** Blocked by ##{ci} — measurement runs *after* parity, never instead of it.

    ## Why this is not the gate

    Decision 6 of #163: **the gate is corpus parity.** Memory and throughput are measured after parity is reached, to inform the forecast. A Ruby backend that is fast and small but wrong proves nothing. Do not open this until ##{ci} is closed.

    ## Scope

    Re-run PR #162's harness against the Ruby backend so the numbers are directly comparable to the native ones. Use the same harness, not a new one — a different measurement method makes the comparison worthless.

    ### The native baseline to beat (PR #162, Linux x86_64, PSS)

    | Phase | Single locale (en) | All 49 locales |
    |---|---|---|
    | `require` | +6.2 MB | +6.2 MB |
    | First parse (regex compilation, `Box::leak`, permanent) | +23.9 MB | +535.8 MB |
    | 100 steady-state parses | +0.0 MB | +0.0 MB |
    | **Total over baseline** | **+30.1 MB** | **+542.0 MB** |

    Plus ~43 MB of slug, of which ~30 MB is three unused ABI `.so` files that ship and never load (#159 owns that half).

    ### The prediction to test

    PR #162 compiled all 3,418 extracted patterns as Ruby `Regexp` objects: ~3.2 MB total, ~1.6 KB per pattern, against the Rust `regex` crate's ~141 KB per pattern — **~100x less**. The throughput probe found the practical per-pattern difference is only ~2x on these patterns, and that NER pipeline overhead dominates `Duckling.parse`'s wall time anyway. So the 100x memory cost buys a *guarantee* (Rust `regex`'s O(n) matching), not proportional throughput.

    That is the hypothesis. This issue is where it meets a real backend rather than a bare pattern-compilation probe.

    ## Definition of done

    Measured and published for the Ruby backend, using PR #162's harness:

    - [ ] `require` delta
    - [ ] first-parse delta
    - [ ] all-locale delta
    - [ ] steady-state growth over 100 parses
    - [ ] throughput, against the native backend on the same machine
    - [ ] the ranking layer's own contribution broken out — 468 KB of classifier JSON, six classifiers, `en_xx.json` alone is 167 KB (see ##{I.fetch("rank")})
    - [ ] **Adversarial input check.** Onigmo's O(nm) worst case is the one thing the native backend structurally cannot suffer. Run the Ruby backend against `extreme_inputs_regression.rs`-style adversarial inputs and record what happens. Those files are out of scope as *correctness* coverage, but this is a pathology check, and it is the finding most likely to change the recommendation
    - [ ] Results recorded under `docs/benchmarks/` following the existing per-environment convention (see AGENTS.md)
  MD
)
link(163, meas); puts "meas -> ##{meas}"

fc = create(
  title: "Ruby backend Phase 4 — publish the go/no-go forecast for the remaining 26 locales",
  labels: %w[ruby-backend phase-4 documentation],
  body: <<~MD
    Parent: #163 · **Phase 4 — reduce.** Blocked by ##{meas}. This is the deliverable the whole issue exists to produce.

    ## Scope

    A forecast document in tree stating **what EN cost** and **what the remaining 26 locales are projected to cost**.

    #163 is a *test-drive*, not a commitment. Its stated goal is "carrying a continually-updated go/no-go forecast until all 27 time-supporting locales are covered, or the forecast says stop." This document is where "stop" becomes sayable.

    ## What it has to answer

    - [ ] **What EN actually cost.** Agent-hours or wall-clock across 38 Phase 2 slices and 42 Phase 3 audits; how many slices needed sub-splitting; how many spine follow-ups the frozen-files rule generated
    - [ ] **What EN actually bought.** The measured numbers from ##{meas} against the native baseline — memory, throughput, and the adversarial-input result
    - [ ] **The per-locale projection, and its error bars.** EN is `dimensions/time/en.rs` at 5,169 lines and 221 rules. The other 26 time-supporting locales are smaller, but not proportionally — and the EN port had the benefit of a 1,034-case corpus that **no other locale has**. State plainly that Milestone 2+ has no oracle of the same quality, and what that does to the estimate
    - [ ] **Where the corpus-TDD method broke down**, if it did. The 23 rules with no `TimeForm` were invisible in #163's own slicing plan until the rule map was derived; say what else the method missed
    - [ ] **A recommendation**: continue to Milestone 2 (FR), or stop

    ## Milestone 2's role, if the forecast is favourable

    FR is the calibration point, not an arbitrary next locale: it is the **largest per-locale memory cost PR #162 measured (+26.8 MB)** and `dimensions/time/fr.rs` is 1,479 lines. Its purpose is to calibrate the per-locale port cost against this document's EN estimate. Open it as a follow-up issue only if this forecast says go.

    ## Explicitly out of scope for the recommendation

    Per #163: replacing the native backend as the default, or changing what the gem ships. This forecast informs a future decision; it does not make it.
  MD
)
link(163, fc); puts "forecast -> ##{fc}"

h = ids; h["phase4"] = {"ci" => ci, "measure" => meas, "forecast" => fc}
File.write(File.join(__dir__, "created.json"), JSON.pretty_generate(h))
