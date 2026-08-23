# stage200-issue-ops

Turns the analysis output into GitHub issues. **These stages write.** Read the
idempotency note below before running any of them.

Run in order — each stage's templates reference numbers the previous ones
recorded:

```sh
DRY_RUN=1 ruby stage210-create-serial-blockers/run.rb   # preview first
ruby stage210-create-serial-blockers/run.rb
ruby stage220-create-timeform-slices/run.rb
ruby stage230-create-dependency-dimensions/run.rb
ruby stage240-create-corpus-tickets/run.rb
ruby stage250-create-corpus-audits/run.rb
ruby stage260-create-reduce-stage/run.rb
ruby stage210-create-serial-blockers/run.rb              # again: fills in the corpus gate numbers
ruby stage270-post-orchestration-index/run.rb
```

| Stage | Creates |
|---|---|
| `stage210-create-serial-blockers` | the spine, the ranking layer, fixture capture |
| `stage220-create-timeform-slices` | 37 `TimeForm` slices + the modifier slice |
| `stage230-create-dependency-dimensions` | numeral, duration, ordinal, time_grain |
| `stage240-create-corpus-tickets` | glob split, unexercised branches, unreached rules, `with_latent` |
| `stage250-create-corpus-audits` | the audit parent + one audit per slice |
| `stage260-create-reduce-stage` | CI parity, measurement, forecast |
| `stage270-post-orchestration-index` | the index comment on the parent issue |

## Idempotency, and the one way to break it

Every create goes through `GitHub.upsert`, which keys on a **pipeline name**
(`"slice:Interval"`), not a title. If `../issue-ledger.json` already has a
number for that key it edits; otherwise it creates and records. So rerunning a
stage after editing its template updates the live issues in place.

Delete or lose `issue-ledger.json` and the next run mints a full duplicate set.
Nothing in the GitHub API objects. It is the only piece of state that matters
here, and it is why `DRY_RUN=1` exists.

## Why stage210 runs twice

Fixture capture is gated on the whole corpus stage, so its body names issues
that do not exist when it is first created. The first run writes `TBD`; the
rerun, after stage240 and stage250, fills in real numbers. Cheap, and it beats
a topological sort over a dependency graph that has exactly one back edge.

## Where the prose lives

Issue bodies are `*.md.erb` beside the runner that renders them, so a change to
what an issue *says* never means reading Ruby. Blocks shared across stages are
partials in `../stage000-shared/partials/`. Judgement calls that cannot be
derived from the crate — wave descriptions, which slices are too big, why each
dependency dimension matters — sit in `notes.yml` / `dimensions.yml` next to
the templates that read them.

## History: what this pipeline does not replay

The live tree was built in a different order than these stages run. The 42
audits were first created as a post-port "Phase 3", then retargeted to run
before the port once the corpus sweep showed how much the corpus was missing.
Those retargeting passes are not modelled here — a fresh run creates the audits
in their final form directly. The live issue numbers in `issue-ledger.json`
still reflect the original creation order, which is why they are not
contiguous by stage.
