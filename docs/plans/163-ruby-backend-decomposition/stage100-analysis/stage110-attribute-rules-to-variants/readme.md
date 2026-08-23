# stage110 — attribute rules to variants

For each `Rule { ... }` in `src/dimensions/time/en.rs`, what does its
production closure construct, and which `TimeData` attribute fields does it
write?

- **builds** — `TimeData::new(TimeForm::X)` / `TimeData::latent(TimeForm::X)`,
  plus three helpers that construct indirectly: `compose()` and
  `intersect_dom()` build `Composed`, `month_day()` builds `DateMDY`,
  `apply_ampm()` builds `HourMinute`.
- **mutates** — `latent`, `early_late`, `open_interval_direction`, `timezone`,
  `direction`, `ok_for_this_next`.

A rule with an empty `builds` is a modifier: it clones an existing `TimeData`
and changes a flag. There are 23, and they became a slice of their own.

## Why a rule's block ends where its braces balance

The obvious parse is "from `Rule {` to the next `Rule {`". That is wrong for
the last rule in the file, which then runs to EOF and absorbs the helper
functions below it. It silently mis-attributed `"Mid-day"` — which plainly
builds `HourMinute(12, 0, false)` — to `Hour`, because `apply_ampm` further
down the file mentions `Hour`. Brace balancing fixes it.

Output: `out/rule_attribution.json` — 221 entries.
