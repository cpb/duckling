# stage210 — create serial blockers

The three issues that gate everything else.

| Template | Issue |
|---|---|
| `phase0_spine.md.erb` | the ~1,940-line engine spine, the backend switch, the base classes, the fixture format |
| `ranking_layer.md.erb` | `src/ranking/mod.rs` and the six trained classifiers |
| `phase1_fixture_capture.md.erb` | replay the corpus through the native backend, bucketed per slice |

## Why the spine is one issue and everything after it is 42

The spine defines the base classes, the self-registration protocol and the
fixture format. Until those are stable, parallel slices cannot each own four
files and touch nothing else — they would each invent their own. That is the
whole reason this stage is serial.

Ranking is split out rather than bundled with the spine because it scores
whatever the engine produced and is independent of the rules, so once the base
classes land it can run alongside all of Wave A.

## This stage runs twice

Fixture capture is gated on the entire corpus stage, whose issues do not exist
on a first run. The first pass writes `TBD`; rerun after stage240 and stage250
and the real numbers appear. The alternative is a topological sort over a
dependency graph with exactly one back edge, which is not worth it.
