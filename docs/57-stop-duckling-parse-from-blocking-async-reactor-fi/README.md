# Issue #57: Stop `Duckling.parse` from Blocking the Async Reactor

Research-and-planning tree for
[issue #57](https://github.com/cpb/duckling/issues/57). `Duckling.parse` is
a synchronous Rust FFI call that holds Ruby's GVL for its entire duration;
inside an `Async::Reactor` (e.g. Falcon), which cooperatively schedules
`Fiber`s on a single OS thread, this stalls every sibling Fiber for the
duration of the call. `test/falcon_fiber_blocking_test.rb` proves this
empirically (currently failing, max ticker gap ≈ the parse call's own
duration).

This PR is documentation only — no application code
(`ext/duckling/`, `lib/`) changes. It maps the terrain and proposes a
grounded, empirically-verified plan for a future implementation PR to
execute against. It is stacked as a PR train on top of
[#50](https://github.com/cpb/duckling/pull/50) (issue #38's branch, which
introduced the failing hill test this issue is scoped to fix).

## Reading order

1. Start with **[Research](research/README.md)** — five parallel-researched topics covering the mechanism, the wrapped crate's thread-safety, an empirical prototype spike, dispatch-strategy alternatives, and test/CI compatibility.
2. Then **[Plans](plans/README.md)** — two documents synthesizing the research into one recommended, concrete implementation shape.

## Table of contents

| Document | Summary |
|---|---|
| [Research](research/README.md) | Breadth-first summary and TOC of all five research topics. |
| [Plans](plans/README.md) | Breadth-first summary and TOC of both plan documents. |

## The headline finding

Releasing the GVL alone does **not** fix the reactor-blocking behavior on
this gem's Ruby floor (gemspec `>= 3.2.0`, CI pins `3.3.6`) — confirmed
empirically in
[Fiber-Scheduler Mechanism Spike](research/fiber-scheduler-mechanism-spike/README.md).
A fix needs *both* a raw GVL release (via `rb_thread_call_without_gvl`,
since Magnus 0.8.2 has no safe wrapper for it — see
[Releasing the GVL Around `duckling::parse` with Magnus + rb-sys](research/magnus-rb-sys-gvl-release/README.md))
*and* dispatch onto a genuine background `Thread`, because the Ruby VM
feature that would otherwise make a bare GVL release sufficient
(`Fiber::Scheduler#blocking_operation_wait`) only exists in Ruby 3.4+. The
recommended concrete shape is laid out in
[Plan: GVL-Release Implementation for `Duckling.parse`](plans/01-gvl-release-implementation.md).
