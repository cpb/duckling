# Issue #32 — serde_magnus + `Data` objects vs. manual Magnus mapping: comparison

This documents the cutover from 0.2.0's "Option B" (manual `RHash`/`RArray` construction in
`ext/duckling/src/lib.rs`) to "Option D" (`serde_magnus::serialize` + an in-place key-symbolizer +
Ruby `case/in` factories building `Data` value objects), landed for 0.3.0. See the issue for full
background; this doc covers what was actually measured and found while building it, not the
proposal as originally sketched.

## Code size

| | Option B (0.2.0) | Option D (0.3.0) |
|---|---|---|
| Rust conversion layer | ~69 lines (`entity_to_ruby`/`time_value_to_ruby`/`time_point_to_ruby`), handling only `DimensionValue::Time` — every other dimension silently produced no `:value` | ~30 lines (`symbolize_keys_in_place`), generic over every `DimensionValue` variant — Numeral, Email, Quantity, etc. all get a populated `value` for free |
| Ruby layer | none — raw `Hash` returned directly | ~71 lines (`lib/duckling/entities.rb`) — `Data` classes plus the `case/in` factory that builds them |

Net: less Rust, more Ruby, and (unlike 0.2.0) every dimension now returns a value of some kind. The
new Ruby layer is where the "hashes aren't a great end-user API" premise pays off — immutable objects
with named accessors instead of a Hash shape callers had to memorize — but it's real code that Option B
never needed.

## Shape differences found while building this (not obvious from the design doc)

- **`Entity` has no `dim` field in the wrapped Rust crate.** 0.2.0's `:dim` key was synthesized from
  `entity.value.dim_kind()`, a Rust-side convenience method with no serialized equivalent. The new
  Ruby factory derives `dim` from *which `case/in` arm matched* the tagged `value` payload instead.
- **`DimensionKind::Numeral` displays as `"number"`**, not `"numeral"` — the PascalCase serde tag
  (`"Numeral"`) doesn't match a naive downcase of the dimension name. Needed an explicit lookup table
  (`DIM_SYMBOLS`) to preserve 0.2.0's `:number` vocabulary; everything else in that table matches a
  simple hyphenated-downcase rule.
- **`Grain::NoGrain` needs the same treatment**: serde's bare `"NoGrain"` naively downcased gives
  `:nograin`, not `:no_grain`. In practice `Grain::NoGrain` turned out not to be reachable through any
  natural-language input we tried — it's used internally while resolving `TimeForm::Now` but gets
  normalized to `Grain::Second` before a resolved `Entity`'s `TimePoint` is ever built — so this is
  pinned with a direct unit test of the lookup table (`grain_symbol("NoGrain") == :no_grain`) rather
  than an end-to-end parse assertion.
- **`TimeValue::Interval`'s `from`/`to` serialize as `null` when unbounded**, not an omitted key (they
  have no `skip_serializing_if`, unlike `Entity.latent` and `TimeValue`'s `holiday`, which do). The
  Ruby factory handles this uniformly (`from && time_point(from)`), so it's not a behavioral gap, just
  worth knowing if you're inspecting `Duckling::Native.parse`'s raw output directly.
- **Ruby hash-pattern gotchas** (verified live, not just from docs): naming an optional key directly in
  an `in {...}` pattern (e.g. `holidayBeta:`) makes the *entire* pattern fail to match when that key is
  absent — `Entity.latent`/`TimeValue`'s `holidayBeta` are only present when `Some`, so both are
  captured via `**rest` and read with `.fetch`/`[]` instead. Also, `in {end:, ...}` binds a local
  variable literally named `end`, which is a `SyntaxError` to reference afterward — renamed to
  `end: end_pos` throughout.

## A real GC-safety bug found and fixed during this work

The first version of `symbolize_keys_in_place` collected `(Value, Value)` pairs deleted off a `Hash`
(via Magnus's `ForEach::Delete`) into a plain Rust `Vec`, planning to re-insert them with symbolized
keys after the iteration finished. This crashed (`[BUG] Segmentation fault`) under normal benchmark
load: once a `Value` is deleted from its `Hash` and held only in a Rust-heap `Vec`, it's invisible to
MRI's conservative stack-scanning GC — any further Magnus call that can trigger a GC cycle (which is
most of them) can free the object out from under you. Fixed by staging keys in a Ruby `RArray` instead
(a real, GC-visible Ruby object) and doing `Hash#delete` + `Hash#aset` one entry at a time rather than
batching through Rust-native memory. Verified stable afterward with `GC.stress = true` across 300
`Duckling.parse` calls with no crash. Worth calling out because it's exactly the kind of bug that
passes a normal test run and only shows up under allocation pressure — any future change to this
function should preserve the "never park a bare `Value` in a `Vec`/`Box`/struct field" rule.

## Measured allocation and throughput cost (the actual point of this comparison)

Captured with `bin/benchmark_parse` (`GC.stat[:total_allocated_objects]` diffing + `benchmark-ips`),
before this change (0.2.0, Option B) and after (0.3.0, Option D), same inputs, same machine:

| Input | Objects/call (before → after) | i/s (before → after) |
|---|---|---|
| single time value ("tomorrow") | 38 → 136 (**3.6x**) | ~14.7k → ~8.2k (**~1.8x slower**) |
| time interval ("from 3pm to 5pm") | 37 → 181 (**4.9x**) | ~565 → ~525 (~8% slower, within noise) |
| email ("user@example.com") | 11 → 59 (**5.4x**) | ~26k–65k (noisy) → ~24.9k (within the noisy baseline range) |

The interval case's throughput is barely affected despite the allocation increase because
`duckling::parse`'s own grammar/ranking work for interval expressions dominates wall-clock time far
more than the conversion layer does either way — the allocation-count column is the more meaningful
signal there.

Splitting `Duckling.parse`'s allocation total into its two layers (`Duckling::Native.parse` alone vs.
the full call including the Ruby `Data`-object factory):

| Input | `Native.parse` only | full `Duckling.parse` | Ruby factory layer's share |
|---|---|---|---|
| single time value | 98 | 136 | 38 |
| time interval | 146 | 181 | 35 |
| email | 43 | 59 | 16 |

Two distinct costs are stacked here: `serde_magnus`'s externally-tagged output allocates a `Hash` per
enum layer (`Entity` → `{Time: ...}` → `{Single: ...}` → `{Naive: ...}`, each its own `Hash`, vs. Option
B's single flattened `Hash` per `TimePoint`) — that alone is already ~2.6x Option B's count before any
Ruby-side work happens. The Ruby factory (`Data.new` calls plus `**rest` hash-splitting for the two
optional keys) adds another ~30–40% on top. Neither cost is a bug; both are the price of (a) keeping
the tag-as-discriminant shape `case/in` wants to match on, and (b) building real immutable value
objects instead of handing back the raw Hash. If this overhead matters for a given workload, the
`Duckling::Native.parse` escape hatch (documented in the README) skips the second cost entirely.

## Recommendation

Ship it. The gem is pre-1.0 (0.2.0 → 0.3.0), so this breaking change goes out as a minor bump under
SemVer's pre-1.0 rules, not gated behind a major version. The ergonomics case is strong (immutable
value objects, a preserved Naive/Instant distinction that Option B's `time_value_to_ruby` silently
erased, every `DimensionValue` variant gets a populated `value` instead of just Time), and the Rust
side is both smaller and more generic. The real cost is the measured 3.6–5.4x allocation increase and
roughly 1.8x lower throughput for the dominant single-time-value case — worth knowing about, and worth
revisiting (e.g. building `Data` objects directly from Rust via Magnus's typed-data support, skipping
the intermediate `Hash` entirely) if a workload turns out to be allocation-sensitive, but not
disqualifying for a library whose primary cost is almost always the underlying NLP parse itself, not
the conversion layer around it.
