# stage260 — create the reduce stage

Three issues, strictly serial: parity, then measurement, then the forecast.

| Template | Issue |
|---|---|
| `reduce_ci.md.erb` | both backends run the full corpus in CI |
| `reduce_measure.md.erb` | memory and throughput via PR #162's harness |
| `reduce_forecast.md.erb` | the go/no-go document for the remaining 26 locales |

## The order is the point

Decision 6 of #163: **the gate is corpus parity.** Memory and throughput are
measured *after* parity, to inform the forecast — they are not themselves the
pass condition, because a backend that is fast and small but wrong proves
nothing. Each issue says so and names its blocker, so nobody starts measuring a
backend that does not yet pass.

The CI issue also absorbs what used to be Phase 3's differential. With the
audit moved ahead of the port, there is no second swarm: running the grown
corpus against both backends is the whole residual check.

The forecast is what the entire test-drive exists to produce, including its
licence to say stop.
