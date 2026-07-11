# Plans: pool worker threads for Fiber-scheduler dispatch (issue #71)

One plan, synthesizing all five research topics into a recommendation for
the future `/hill-first` test-writing session.

## Table of contents

| Doc | Summary |
|---|---|
| [01-pool-design-recommendation.md](01-pool-design-recommendation.md) | Recommends a hand-rolled stdlib-only `Queue`-based pool over `concurrent-ruby`. A spike confirmed both designs reach **zero** per-call thread spawns (a bare `Queue#pop`/`Future#value` on the calling Fiber cooperates with `Fiber.scheduler`), so the choice rests on dependency footprint — hand-rolled adds none. Lays out steps tied to issue #71's acceptance criteria (configurable size, clean shutdown, GC-safety, benchmark comparison), and recommends a minimal injectable-dispatch-backend seam (`call(job) -> result`, default to the in-repo pool) so a host already running `concurrent-ruby` can supply its own dispatcher without this gem shipping adapter classes or a new dev dependency. |
