# Recording the `claude-code-web` benchmark data point

`docs/benchmarks/` carries one data point per environment per version. Two of the
three environments are scriptable — `bin/record-all-benchmarks` handles the
`local-<minor>` buckets via rbenv and dispatches `benchmark-branch.yml` for
`github-actions`.

The `claude-code-web` bucket is not. **There is no CLI that launches a Claude Code
Web session**, and no `teleport`-style command: `claude --remote-control` attaches a
*local* session to the mobile app, and `claude ultrareview` is a different
cloud-hosted product. Cloud sessions are spawned from inside a Claude Code session,
via the Agent tool's remote isolation (this is what `/autofix-pr` does — it writes a
`remote-agents/*.meta.json` recording the `taskId` and `sessionId`, not a shell
command).

So this data point needs an agent running in that environment. Spawn a remote agent
and hand it the prompt below.

## Why `benchmark:record` and never `benchmark:record_pr`

`benchmark:record_pr` checks out a fresh branch **off `origin/main`**, records there,
and opens a separate PR. That is correct for a release, and wrong for an unmerged
branch — it would benchmark `main`'s code and label it with your branch's version.

`benchmark:record` records the working tree it is run in. The remote agent commits
that JSON straight to the branch under test.

## The prompt

Substitute `<VERSION>` and `<BRANCH>` before sending.

> You are running in a Claude Code Web session, which is what makes this task
> possible — `bundle exec rake "benchmark:record"` detects `CLAUDE_CODE_REMOTE=true`
> and writes to the `claude-code-web` environment bucket. No other environment can
> produce this data point.
>
> Repo: `cpb/duckling`. Branch: `<BRANCH>`. Do not merge anything, and if that branch
> has an open PR, do not change its draft status.
>
> 1. `git checkout <BRANCH>` and `git pull --ff-only`. This branch is shared with
>    other agents and moves often — always pull before you commit.
> 2. Confirm `Duckling::VERSION` is `<VERSION>`:
>    `ruby -r./lib/duckling/version -e 'puts Duckling::VERSION'`.
>    If it isn't, STOP and report — recording under the wrong version would
>    silently overwrite another commit's data point.
> 3. Run `bundle exec rake "benchmark:record"`. Use exactly this task. Do **not** use
>    `benchmark:record_pr`: it branches off `origin/main`, so it would benchmark code
>    that isn't on this branch and open a PR you didn't ask for.
> 4. Confirm it wrote `docs/benchmarks/claude-code-web/<VERSION>.json` and regenerated
>    `docs/benchmarks/README.md`. That README is generated entirely by
>    `DucklingBenchmark::Report.write_docs_readme!` — never hand-edit it.
> 5. Report the `allocated_objects_per_call` for the `medium` scenario and the
>    `concurrency` block (`scaling_factor`, `efficiency_pct`) from the JSON you just
>    wrote, so the numbers can be sanity-checked against the other environments
>    before anyone trusts them.
> 6. Commit both files with the message
>    `bench: record claude-code-web data point for <VERSION>`, then
>    `git pull --ff-only` and push immediately.
>
> Two things worth knowing about the numbers you'll produce. The cloud sandbox's core
> count bounds 10-thread scaling: if it has fewer than 10 physical cores, the
> resulting `efficiency_pct` measures the sandbox, not the GVL, and must not be used
> to back-solve a serialized fraction (this mistake was made once already against the
> 2–4 vCPU `github-actions` runners). Allocation counts, by contrast, are
> deterministic and comparable across every environment — if `medium` doesn't come
> back within a fraction of an object of what the other environments recorded for the
> same version, something is wrong and you should say so rather than commit it.
