require_relative "gh"
require "json"
I = ids
A1,B1,B2,A2 = I["a1"],I["b1"],I["b2"],I["a2"]
PARENT = I["phase3_parent"]

body = <<~MD
  ## Replan: the gap audit moves ahead of the port

  Measured #255's corpus against the pinned crate — every regex from all 276 EN rules translated to Ruby and tested against all 1,662 case texts — and the result changes the phase order.

  ### What the sweep found

  | Gap class | Size |
  |---|---|
  | Unexercised literal alternation branches | **140** across 23 rules |
  | Rules no corpus text reaches at all | **11** |
  | `with_latent:` coverage | **zero cases**, against 12 latent-producing EN rules |
  | Rules with no regex item — unmeasurable this way | **27** |

  Concrete examples, verified against the fixture: the corpus contains **no timezone abbreviation at all** (21 unexercised across 4 rules), never says **June, November or December**, never exercises **spring, fall or autumn**, and stops at **`fifth`** for ordinal words.

  ### Why that moves Phase 3

  Phase 3 was going to find exactly these — *after* 42 agents had already ported against a spec that omitted them. The corpus-growing half of that audit never needed the Ruby backend; it needs the Rust and the native backend, both of which exist today.

  | | Audit after the port | Audit before the port |
  |---|---|---|
  | A corpus gap | found after the slice merged | never reaches the porting agent |
  | Fixing it | re-open a merged slice | the slice was right the first time |
  | An upstream bug | a three-way disagreement | surfaces cleanly against one backend |

  The outcome that disappears is "fails on Ruby, so it is a port gap" — which only exists because the case arrived too late. Decision 2's oracle property is unharmed: it rests on *different agents* doing the reading and the porting, not on the ordering. Phase 2 agents still never read the Rust; they just get a denser spec.

  ### New gate order

  ```
  PR #255 (closes #157)
    └── ##{A1}  split local fixtures into a globbed directory   [serial]
          ├── ##{B1}  140 unexercised alternation branches      ┐
          ├── ##{B2}  11 rules with no corpus case              │ all
          ├── ##{A2}  with_latent: + the 24 excluded call sites │ parallel
          ├── ##{PARENT} + 42 corpus audits  (label:corpus-audit)  │ 46 issues
          └── #164 spine → #165 ranking                         ┘
    └── #166 fixture capture   [needs corpus stage complete + #164]
          └── wave-a (30) → wave-b (9) → wave-c (3)
                └── #252 → #253 → #254
  ```

  `#164` moves *into* the corpus stage rather than after it: the spine depends on the fixture **format**, not on corpus **content**. `#166` is the real gate, because it buckets whatever corpus exists when it runs and its output is every slice's spec.

  ### What changed on existing issues

  - **#210–#251 retargeted** — retitled `Corpus audit: …`, relabelled `corpus-audit`, moved before Phase 2, native backend only, two outcomes instead of three. Each now carries **its own slice's pre-identified gaps** so no agent redoes ##{B1}/##{B2}'s work, and each writes to its own `test/fixtures/wafer_corpus_local/<slice>.json` — which is what ##{A1} exists to allow.
  - **##{PARENT} retargeted** as the corpus-audit parent.
  - **#166 gated** on the corpus stage completing.
  - **#252 absorbs the residual differential.** There is no second swarm; running the grown corpus against both backends in CI is what catches a mis-port, on a case that already existed when the slice was written.
  - **`phase-3` label retired**; nothing carries it.
  - The 42 Phase 2 slice issues needed **no edit** — their stated dependency on #166 carries the new gate automatically.

  ### One risk this creates, and the guard for it

  The corpus becomes the Ruby backend's specification. An audit agent that meets surprising native behaviour and pins it as golden turns an upstream bug into a *required* behaviour. Every audit issue says so explicitly and requires the divergence be filed upstream instead. This is worth watching in review.

  ### Side finding: the regex-dialect risk looks smaller than assumed

  All 276 patterns translated to Ruby with **zero errors**, needing only `(?P<` → `(?<`. This issue's Notes hold `docs/spike/duckling_patterns.json` in reserve "if a harness turns out to be needed after all" — on this evidence it probably is not. Decision 5 (handle per rule, ad hoc) looks right.

  ### Method caveat

  A branch matching no corpus text is definitely unexercised. The converse does not hold — a branch that appears in some text may still never fire, because another rule can win the span. 140 and 11 are **lower bounds**, and the 26 slices the sweep found clean are only clean as far as the technique sees. The 27 rules with pure `predicate`/`dim` patterns are invisible to it entirely, which is why the 42-way audit still runs.
MD
File.write("/tmp/c2.md", body)
sh("gh", "issue", "comment", "163", "-R", REPO, "-F", "/tmp/c2.md")
puts "commented on #163"
