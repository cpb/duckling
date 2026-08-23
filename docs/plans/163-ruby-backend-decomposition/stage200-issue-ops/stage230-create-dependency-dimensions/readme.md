# stage230 — create dependency dimensions

Four issues: numeral (23 rules), duration (20), ordinal (4), time_grain (8).

They are Wave A by dependency — no `TimeForm` slice blocks them — but most
Wave A time slices consume their tokens, so in practice they want to start
first. `dimensions.yml` records that relationship per dimension, which is the
part an assignee cannot read off the crate:

- **numeral** — every slice taking an integer goes through `integer_value()`
- **duration** — `DurationAfter` and six of `Interval`'s rules
- **ordinal** — the five `Nth*` variants and the `<ordinal> <month>` dates
- **time_grain** — `Grain` is in every resolved value, so it blocks the
  fixture format itself

Rule counts and file paths come from the crate. Only the prose is written.
