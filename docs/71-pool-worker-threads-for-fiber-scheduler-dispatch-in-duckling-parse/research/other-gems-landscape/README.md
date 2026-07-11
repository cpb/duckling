# Research: the rest of the Ruby thread-pool gem landscape

Scope: issue #71 needs a reusable worker-thread pool to replace the per-call
`Thread.new { Native.parse(...) }.value` spawn in `Duckling.parse`'s
Fiber-scheduler dispatch path (`lib/duckling.rb`). Two sibling research
topics cover `concurrent-ruby`'s executors and a hand-rolled minimal pool in
depth. This document surveys the rest of the standalone-gem landscape, so
the plan agent can compare "adopt a small purpose-built gem" against those
two options on maintenance/adoption grounds, per the issue's stated
preference for the most actively maintained/adopted option.

## Existing dependency tree check

Checked `duckling.gemspec` and `Gemfile.lock` in this checkout: no
thread-pool-shaped gem is present, directly or transitively. `Gemfile.lock`'s
only thread/fiber-scheduler-adjacent entries are `async`, `io-event`,
`console`, `fiber-annotation`, `fiber-local`, `fiber-storage`, and `traces` —
all Fiber-scheduler *plumbing* (pulled in as a `spec.add_development_dependency
"async"`, used only by `test/falcon_fiber_blocking_test.rb` and
`benchmark/parse_benchmark.rb` — see `duckling.gemspec`'s comment above that
line), not a thread-pool implementation. Adopting any candidate below would
be a genuinely new runtime dependency.

## New territory: candidate comparison table

All download counts and release dates pulled from each gem's rubygems.org
page; issue/commit data pulled from each project's GitHub API on 2026-07-07.

| Gem | Latest version | Latest release | Total downloads | GitHub stars | Open / closed issues (non-PR) | Last commit | Dependabot config | Verdict |
|---|---|---|---|---|---|---|---|---|
| [`concurrent-ruby`](https://rubygems.org/gems/concurrent-ruby) | 1.3.7 | 2026-06-16 | 1,313,544,732 | (widely embedded — see sibling research doc) | (see sibling research doc) | active | n/a — see sibling doc | **Reference point only** (own research topic). Overwhelmingly the largest download count of anything in this landscape by ~3 orders of magnitude; still receiving releases as of last month. Nothing below is competitive with it on adoption. |
| [`workers`](https://rubygems.org/gems/workers/versions/0.6.1) ([GitHub](https://github.com/chadrem/workers)) | 0.6.1 | 2017-12-08 | 4,391,848 | 247 | 1 open / 7 closed (13 total incl. non-issue) | 2020-11-18 (README-only commit; last code commit 2018-03-31) | Not present ([404 on `.github/dependabot.yml`](https://github.com/chadrem/workers)) | Dormant. Meaningful historical adoption (4.4M downloads, 247 stars) but no release in 8+ years and no code commits since 2018 — a doc-only commit in 2020 is the most recent activity. |
| [`dat-worker-pool`](https://rubygems.org/gems/dat-worker-pool/versions/0.6.3) ([GitHub](https://github.com/redding/dat-worker-pool)) | 0.6.3 | 2016-06-28 | 31,270 | 1 | 1 open / 3 closed | 2018-04-04 (dependency-version hotfix) | Not present (404) | Abandoned. Low stars/downloads, no activity since 2018. |
| [`threadpool`](https://rubygems.org/gems/threadpool/versions/0.1.2) ([GitHub](https://github.com/meh/ruby-threadpool)) | 0.1.2 | 2012-06-23 | 157,268 | — | — | — | Not checked (repo effectively unmaintained; last release 2012) | Abandoned. 14 years since last release. |
| [`thread_pool`](https://rubygems.org/gems/thread_pool/versions/0.0.0) | 0.0.0 | 2009-10-10 | 7,303 | — | — | — | n/a | Explicitly a **placeholder gem** — its own rubygems.org description says "Placeholder for a gem to be migrated later." Never implemented. Not a real candidate. |
| [`ruby_thread_pool`](https://rubygems.org/gems/ruby_thread_pool/versions/0.1.0) | 0.1.0 | 2012-05-18 | 12,220 | — | — | — | Not checked | Abandoned, single release, minimal adoption. |
| [`em-worker-pool`](https://rubygems.org/gems/em-worker-pool/versions/0.1.0) | 0.1.0 | 2013-04-30 | 4,670 | — | — | — | Not checked | Abandoned; also EventMachine-specific (a reactor model orthogonal to the Fiber-scheduler problem this issue is solving), so architecturally not a fit even ignoring maintenance status. |

### Sidekiq / Puma internal pools

Both Sidekiq and Puma implement their own internal worker-thread-pool logic
(Sidekiq's job-processing thread pool, Puma's `ThreadPool` class used by its
HTTP server). Neither extracts this as a standalone reusable library — it's
private implementation detail wired directly into each project's own
job-dispatch or request-dispatch loop, not published as an independent gem
or a documented public API meant for external `require`. Vendoring or
depending on either directly would mean depending on an internal
implementation detail of a much larger gem (with its own release cadence
tied to job-queue/web-server concerns unrelated to this problem), not
adopting a purpose-built thread-pool library. Noted here as ruled out on
architectural grounds, not further evaluated for maintenance signals.

## Ranking (most to least actively maintained/adopted)

1. **`concurrent-ruby`** — active releases (most recent 2026-06-16), by far
   the largest download count of anything considered (1.31B vs. `workers`'
   4.39M as the next-highest). Covered in depth by the sibling
   `concurrent-ruby` research topic; included here only to anchor the
   ranking.
2. **`workers`** (chadrem/workers) — the only standalone-gem alternative
   with a real adoption signal (4.39M downloads, 247 GitHub stars, low
   but non-zero recent issue engagement historically), but dormant: no
   release since December 2017, no code commit since March 2018. A team
   picking this up today would be adopting an unmaintained dependency,
   full stop — any bug or Ruby-version-compat issue would need to be
   patched downstream or vendored, not fixed upstream.
3. **`dat-worker-pool`** — real but far smaller adoption (31K downloads, 1
   star), same "abandoned since ~2018" pattern as `workers`, no Dependabot.
4. **`threadpool`**, **`ruby_thread_pool`**, **`em-worker-pool`**,
   **`thread_pool`** — all either single-digit-years-stale placeholder
   gems or minimal-adoption abandonware; `thread_pool` in particular is
   explicitly not a real implementation per its own gem description.
   `em-worker-pool` is additionally architecturally mismatched (built for
   EventMachine's reactor, not Ruby's `Fiber::Scheduler` interface this
   issue targets).

None of the standalone-gem candidates below `concurrent-ruby` have a GitHub
Dependabot (or equivalent) configuration — checked via a direct
`.github/dependabot.yml` lookup against each repo's default branch, which
404'd for both `workers` and `dat-worker-pool` (the two candidates whose
repos were viable enough to check). That absence is itself a data point:
none of these small gems have kept even automated dependency-update tooling
running, consistent with all of them predating Dependabot's 2019 GitHub
acquisition/rollout and never having been touched since to add it.

## Bottom line for the plan agent

This survey did not surface a standalone gem — other than `concurrent-ruby`
itself — that is both actively maintained and meaningfully adopted. The
"rest of the landscape" beyond `concurrent-ruby` consists entirely of small,
single-maintainer gems that stopped receiving commits between 2012 and 2020
and have no Dependabot/CI modernization since. Any plan that wants a
maintained dependency for this pool, rather than a hand-rolled
implementation, is effectively choosing between `concurrent-ruby` (covered
by the sibling research doc) and writing the pool in-repo (covered by the
other sibling research doc) — not between `concurrent-ruby` and some other
overlooked gem.
