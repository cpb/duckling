# Memory footprint spike

Empirical measurement of the memory cost of requiring and using the
`duckling` gem, at both the Heroku slug level and the runtime process level.

## How to run

### Locally (macOS)

```sh
ruby docs/spike/memory_footprint.rb
```

Reports RSS only (no PSS/USS on macOS).

### Linux via Docker (matches Heroku's runtime)

```sh
docker build -t duckling-mem -f docs/spike/memory_footprint.Dockerfile .
docker run --rm duckling-mem
```

Change the `FROM` line to `ruby:3.4-slim` (or `ruby:3.2-slim`) to measure
a different Ruby ABI. The precompiled platform gem carries a `.so` for each.

## What it measures

The harness walks four phases, with `GC.start` forced between each so
deltas reflect committed memory, not transient garbage:

1. **Baseline** — bare Ruby, nothing required
2. **After `require "duckling"`** — the `.so` is dlopen'd and the Magnus
   `#[init]` runs (registers `Duckling::Native.parse`)
3. **Per-locale first parse** — iterates all 49 supported locales, parsing
   `dims: ["time"]` for each. The Rust `duckling` crate compiles grammar
   rules lazily per locale via `OnceLock`, then leaks them via `Box::leak`
   — each locale's first parse is a permanent, one-time memory cost. 27
   locales have time-dimension rules; the remaining 22 still compile
   dependency-dimension rules (numeral, ordinal, duration, time-grain)
   plus shared English common rules.
4. **100 steady-state parses** — cycles through locales that produced
   results, to verify zero growth once all caches are warm.

On Linux it also prints `/proc/self/smaps` detail for the `duckling.so`
mapping and the full `/proc/self/smaps_rollup`.

## Findings (2026-08-20, duckling 0.4.7)

### Slug level (Heroku disk)

| Component | Size |
|-----------|------|
| Gem download (`.gem`, compressed) | ~12 MB |
| Unpacked: 4 × `.so` (Ruby 3.2, 3.3, 3.4, 4.0) | ~40 MB |
| Unpacked: Ruby code + docs | ~72 KB |
| Dependencies (tzinfo + concurrent-ruby) | ~2 MB |
| **Total slug addition** | **~43 MB** |
| **Wasted** (3 unused ABI `.so` files) | **~30 MB** |

The platform gem ships 4 separate `.so` files, one per Ruby ABI. Only one
is ever loaded at runtime — the other three are pure slug waste.

### Single-locale runtime (Linux x86_64, PSS)

| Phase | Ruby 3.3 | Ruby 3.4 |
|-------|----------|----------|
| Baseline | 12.0 MB | 12.8 MB |
| After `require` | 18.2 MB | 18.3 MB |
| After 1st parse (en, time) | 42.1 MB | 40.4 MB |
| After 100 parses | 42.1 MB | 40.4 MB |

| Delta | Ruby 3.3 | Ruby 3.4 |
|-------|----------|----------|
| `require` (.so load + tzinfo) | +6.2 MB | +5.5 MB |
| First parse (regex compilation) | +23.9 MB | +22.1 MB |
| 100 parses (steady state) | +0.0 MB | +0.0 MB |
| **Total over baseline** | **+30.1 MB** | **+27.6 MB** |

### All-locale runtime (Linux x86_64, PSS)

| Phase | Ruby 3.3 | Ruby 3.4 |
|-------|----------|----------|
| Baseline | 12.0 MB | 12.8 MB |
| After `require` | 18.2 MB | 18.3 MB |
| After all 49 locales (1st parse each) | 554.0 MB | 554.2 MB |
| After 100 steady-state parses | 554.0 MB | 554.2 MB |

| Delta | Ruby 3.3 | Ruby 3.4 |
|-------|----------|----------|
| `require` (.so load + tzinfo) | +6.2 MB | +5.5 MB |
| All 49 locales (regex compilation) | +535.8 MB | +535.8 MB |
| 100 steady-state parses | +0.0 MB | +0.0 MB |
| **Total over baseline** | **+542.0 MB** | **+541.4 MB** |

### Per-locale growth (Linux x86_64, Ruby 3.3, RSS)

Locales with time-dimension rules (27) — each compiles time + dependency
dimensions (numeral, ordinal, duration, time-grain) plus English common
rules:

| Locale | Entities | Growth |
|--------|----------|--------|
| en | 1 | +10.5 MB |
| ga | 1 | +11.1 MB |
| ro | 1 | +11.2 MB |
| hu | 1 | +11.6 MB |
| es | 1 | +15.4 MB |
| he | 1 | +15.2 MB |
| ko | 1 | +16.2 MB |
| ka | 1 | +16.2 MB |
| sv | 1 | +16.8 MB |
| bg | 1 | +17.0 MB |
| nl | 1 | +17.8 MB |
| vi | 2 | +19.5 MB |
| uk | 1 | +19.8 MB |
| ja | 1 | +19.9 MB |
| el | 1 | +20.4 MB |
| ca | 1 | +20.9 MB |
| ar | 1 | +21.3 MB |
| it | 1 | +21.9 MB |
| pt | 1 | +22.2 MB |
| de | 1 | +22.5 MB |
| nb | 1 | +23.5 MB |
| pl | 1 | +23.6 MB |
| ru | 1 | +23.8 MB |
| hr | 1 | +24.1 MB |
| tr | 1 | +24.1 MB |
| fr | 1 | +26.8 MB |
| zh | 1 | +15.2 MB |

Locales without time-dimension rules (22) — compile only dependency
dimensions + English common rules; many show 0 KB growth on Linux because
glibc malloc reuses already-committed pages for the small allocations:

| Locale | Growth |
|--------|--------|
| af | +4.6 MB |
| fa | +0.4 MB |
| fi | +1.0 MB |
| lo | +0.1 MB |
| ml | +0.1 MB |
| mn | +1.0 MB |
| my | +1.8 MB |
| bn, cs, et, hi, id, is, km, kn, ne, sk, sw, ta, te, th | +0.0 MB |

### The `.so` in RSS (from `/proc/self/smaps`)

After all 49 locales, the `.so`'s file-backed pages are nearly fully
resident (more code paths exercised than the single-locale case):

| Segment | Virtual | Single-locale RSS | All-locale RSS |
|---------|---------|-------------------|----------------|
| r--p (headers/rela) | 692 KB | 696 KB | 696 KB |
| r-xp (text) | 5,276 KB | 3,356 KB | 5,276 KB |
| r--p (rodata/eh_frame) | 2,008 KB | 940 KB | 1,196 KB |
| rw-p (data.rel.ro/got) | 543 KB | 544 KB | 544 KB |
| **Total** | **8,517 KB** | **5,536 KB (5.4 MB)** | **7,712 KB (7.5 MB)** |

### The 536 MB all-locale cost

From `/proc/self/smaps_rollup` after all 49 locales (Ruby 3.3):

- **Pss_File** (file-backed, includes .so pages): 14.5 MB
- **Pss_Anon** (anonymous heap, Rust regex/rule data): 552.8 MB
- **Pss_Dirty**: 552.8 MB — all anonymous is private/dirty

The dominant cost is the Rust `regex` crate's compiled DFA/bytecode for
~3,900 regex patterns across all locales and dimensions, intentionally
leaked via `Box::leak` (`lang/mod.rs:21`) as `&'static [Rule]` for the
process lifetime. This is a one-time cost: 100 steady-state parses across
all locales add **zero** additional memory.

## Ruby Regexp comparison: would this growth happen in pure Ruby?

The `ruby_regexp_comparison.rb` probe extracts all 3,418 unique regex
patterns from the duckling Rust crate source and compiles them as Ruby
`Regexp` objects (pinned via an instance variable to mirror `Box::leak`),
then runs 100 matches per pattern against a sample string.

### Results (Linux x86_64, Ruby 3.3, PSS)

| | Rust regex crate | Ruby Regexp (Onigmo) |
|---|---|---|
| Patterns compiled | 3,905 (per-locale, with duplicates) | 3,418 (unique, once) |
| Compile memory | ~536 MB (Pss_Anon) | ~3.2 MB (PSS delta) |
| Per-pattern cost | ~141 KB | ~1.6 KB |
| 100 matches memory | +0.0 MB | +0.0 MB |
| Match speed | — | ~1.0M matches/sec |

| | Value |
|---|---|
| **Memory ratio** | **~100x less** for Ruby |
| **Per-pattern ratio** | **~88x less** (normalized for duplicates) |

### Why the difference

**Rust `regex` crate** compiles each pattern into a hybrid DFA/NFA
automaton. The DFA pre-computes all transition states for O(n) matching
time, but the compiled representation is large — ~141 KB per pattern on
average, dominated by the DFA state tables.

**Ruby `Regexp`** (Onigmo) compiles patterns to bytecode that is
interpreted at match time. The compiled bytecode is ~1.6 KB per pattern
— much smaller, but matching is O(nm) worst case (backtracking).

The Rust side also recompiles shared "common rules" per locale (3,905
total compilations vs 3,418 unique patterns) because the `OnceLock`
cache key includes the locale. Even normalizing for duplicates, the
per-pattern cost differs by ~88x.

The tradeoff is speed vs memory: the Rust DFA gives guaranteed linear-time
matching at the cost of ~100x more memory per pattern. For a gem that
compiles ~3,900 patterns on first use, this means 536 MB vs 3 MB — the
difference between a deployment that fits in Heroku's 512 MB Eco dyno and
one that doesn't, if all locales are exercised.

## Runtime performance: does the 100x memory cost buy speed?

The `performance_benchmark.rb` script measures end-to-end throughput and
text-length scaling for both engines.

### Throughput (Linux x86_64, 56-byte text)

| Benchmark | Ruby 3.3 | Ruby 3.4 |
|-----------|----------|----------|
| Duckling.parse (en, full NER pipeline) | 590 ops/sec | 513 ops/sec |
| Duckling.parse (cycling 49 locales) | 916 ops/sec | 935 ops/sec |
| Duckling.parse (cycling 27 time locales) | 527 ops/sec | 519 ops/sec |
| Ruby Regexp.match? (3418 patterns) | 255 iter/sec | 268 iter/sec |
| Ruby Regexp.match? (235 patterns, en) | 6,027 iter/sec | 5,847 iter/sec |
| Ruby Regexp.match? (1 pattern) | 1.03M ops/sec | 1.04M ops/sec |

The "cycling 49 locales" throughput is higher than "en only" because 22
of the 49 locales have no time-dimension rules and parse nearly
instantly, pulling the average down.

### Text-length scaling (Linux x86_64, Ruby 3.3)

| Text | Bytes | Duckling.parse µs | µs/byte | Ruby Regexp (235) µs | µs/byte |
|------|-------|-------------------|---------|----------------------|---------|
| short | 15 | 531 | 35.4 | 89 | 5.9 |
| medium | 56 | 1,629 | 29.1 | 174 | 3.1 |
| long | 173 | 3,120 | 18.0 | 414 | 2.4 |
| xlong | 696 | 18,540 | 26.6 | 1,389 | 2.0 |

Both engines scale roughly linearly with text length. The Rust DFA's
µs/byte is roughly constant (18-35); Ruby's decreases for short text due to
fixed per-iteration overhead (pattern loop setup) and stabilizes around
~2.0 µs/byte for longer text. Neither shows superlinear growth because
the duckling patterns are mostly simple alternations and character
classes that don't trigger Onigmo's catastrophic-backtracking worst case.

### What the numbers mean

Duckling.parse (1,629 µs for en) includes regex matching (235 patterns)
plus tokenization, rule engine, ranking, and Ruby serialization across
the FFI boundary. Ruby Regexp matching (174 µs for 235 patterns) is just
the regex matching — no extraction logic. The 10:1 ratio is not a
regex-engine speed comparison; it's "full NER pipeline" vs "regex only."

The Rust regex engine itself is likely **faster** per-pattern than
Onigmo (DFA O(n) vs backtracking), but the NER pipeline overhead
(Tokio task dispatch, tokenization, rule application, ranking,
serde-magnus serialization) dominates Duckling.parse's wall time. The
~1 µs/pattern from the single-pattern benchmark is Ruby's raw Onigmo
matching speed; the Rust DFA is probably faster still, but it's buried
under ~1,400 µs of pipeline work.

### Bottom line

The 100x memory cost buys a **guarantee** (O(n) matching, no
pathological inputs) rather than proportional throughput. For the
duckling patterns specifically — which are simple enough that Onigmo
doesn't backtrack badly — the practical speed difference at the regex
level is modest. The end-to-end throughput is dominated by the NER
pipeline, not by regex matching, so a hypothetical pure-Ruby
reimplementation using Onigmo would be slower (no O(n) guarantee, plus
Ruby interpretation overhead for the pipeline logic) but would use ~100x
less memory for the regex portion.
