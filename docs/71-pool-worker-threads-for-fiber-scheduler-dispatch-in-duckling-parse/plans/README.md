# Plans: pool worker threads for Fiber-scheduler dispatch (issue #71)

One plan, synthesizing all five research topics into a recommendation for
the future `/hill-first` test-writing session.

## Table of contents

| Doc | Summary |
|---|---|
| [01-pool-design-recommendation.md](01-pool-design-recommendation.md) | Recommends a hand-rolled stdlib-only `Queue`-based pool over `concurrent-ruby`, since neither eliminates per-call thread spawning and hand-rolled's version of that ceiling is mechanically proven rather than hypothesized. Lays out steps tied to issue #71's acceptance criteria (configurable size, clean shutdown, GC-safety, benchmark comparison) and flags four open questions. |
