require_relative "gh"

CONSTRAINTS = <<~MD
  ## Constraints inherited from #163

  - **Placement.** `lib/duckling/ruby/`, behind a backend switch. The native backend stays the default and ships unchanged.
  - **No Rust at runtime.** The Ruby backend must load and parse with no native extension present.
  - **No central registry file.** Loading is `Dir.glob`-based and every file self-registers on load. A hand-edited `require` manifest would be a guaranteed 40-way conflict.
  - **Shared files are frozen after Phase 0.** A slice that needs a spine change files a follow-up issue rather than editing in place.
  - **Fixtures are generated, never hand-written.**
  - **Pinned crate version: duckling 0.4.0.**
MD

REGEX_NOTES = <<~MD
  ## Regex dialect notes (decision 5: handled per rule, ad hoc)

  - `(?i)` is applied crate-wide by `pattern.rs`'s `regex()` helper, which prefixes every pattern. The Ruby side applies the same blanket case-insensitivity rather than relying on per-pattern flags.
  - Rust `regex` has no backreferences and no lookaround; Onigmo has both. Translation is one-directional and should mostly be verbatim.
  - `\\b` word-boundary semantics differ on non-ASCII input. The crate leans on `\\b` heavily.
  - Rust's leftmost-first alternation and Onigmo's backtracking order are not identical. A rule whose alternation branches overlap can match a different span.
  - PR #162's `docs/spike/duckling_patterns.json` holds all 3,418 extracted patterns if a compatibility harness turns out to be needed.
MD

p0 = create(
  title: "Ruby backend Phase 0 — engine spine, backend switch, base classes, fixture format",
  labels: %w[ruby-backend phase-0 pr-train test-first],
  body: <<~MD
    Parent: #163 · **Phase 0 — serial, one agent, blocks everything.**

    ## Scope

    Port the ~1,940-line engine spine of duckling 0.4.0 to pure Ruby under `lib/duckling/ruby/`, and ship the backend switch. This is the only issue in the tree that may create the shared files; everything after it is forbidden from editing them.

    | Rust file | Lines | What it owns |
    |---|---|---|
    | `src/engine.rs` | 853 | the rule-matching loop, parse limits, node expansion |
    | `src/types.rs` | 492 | `Rule`, `Node`, `TokenData`, `DimensionKind`, `Entity` |
    | `src/locale.rs` | 277 | locale resolution |
    | `src/resolve.rs` | 167 | entity resolution |
    | `src/document.rs` | 71 | document / tokenization |
    | `src/stash.rs` | 56 | the stash |
    | `src/pattern.rs` | 24 | `regex()` / `dim()` / `predicate()` pattern items |

    ## Definition of done

    - [ ] `lib/duckling/ruby/` exists behind a backend switch; `Duckling.parse` still routes to the native backend by default, unchanged
    - [ ] The Ruby backend loads and runs with no native extension present (no `require` of the compiled `.so`/`.bundle` on that path)
    - [ ] Document/tokenization, `PatternItem` (regex / dimension / predicate), the rule-matching loop, the stash, `Context`/`Options`, locale resolution, and entity resolution are ported
    - [ ] **Parse limits reproduced exactly**: 256 regex matches per rule, 256 rule results, 1,024 new nodes per iteration, 3,000 nodes, 24 iterations. #130 tracks the entity cap being a silent truncation — reproduce the current behavior, do not fix it here
    - [ ] A handful of synthetic rules prove the pipeline end to end
    - [ ] **Base classes are defined and documented**: the form-resolver base, the rule base, and the self-registration protocol every later slice depends on
    - [ ] **The fixture format is defined and documented** — this is the contract Phase 1 writes and 42 slices read
    - [ ] `Dir.glob` loading is in place for `lib/duckling/ruby/time/forms/*.rb` and `lib/duckling/ruby/rules/en/*.rb`
    - [ ] `bundle exec rake` green; native backend behavior byte-identical

    ## Why this blocks everything

    Every Phase 2 slice creates exactly two `lib/` files and two `test/` files and touches nothing else. That only works if the base classes, the self-registration protocol and the fixture format already exist and are stable. Land those wrong and 42 parallel agents each invent their own.

    #{CONSTRAINTS}
    #{REGEX_NOTES}
  MD
)
record("p0", p0)
link(163, p0)
puts "P0 = ##{p0}"
