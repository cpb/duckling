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

Four phases, with `GC.start` forced between each so deltas reflect
committed memory, not transient garbage:

1. **Baseline** — bare Ruby, nothing required
2. **After `require "duckling"`** — the `.so` is dlopen'd and the Magnus
   `#[init]` runs (registers `Duckling::Native.parse`)
3. **After first `Duckling.parse`** — the Rust `duckling` crate lazily
   compiles ~235 regex patterns and ~221 Rule structs for the English
   `time` dimension via `OnceLock`, then leaks them via `Box::leak`
4. **After 100 more parses** — steady state; should be zero growth

On Linux it also prints `/proc/self/smaps` detail for the `duckling.so`
mapping and the full `/proc/self/smaps_rollup`.

## Findings (2026-08-19, duckling 0.4.7)

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

### Runtime memory (Linux x86_64, Docker, PSS)

| Phase | Ruby 3.3 | Ruby 3.4 |
|-------|----------|----------|
| Baseline | 11.9 MB | 13.0 MB |
| After `require` | 18.0 MB | 18.5 MB |
| After 1st parse | 42.1 MB | 40.4 MB |
| After 100 parses | 42.1 MB | 40.5 MB |

| Delta | Ruby 3.3 | Ruby 3.4 |
|-------|----------|----------|
| `require` (.so load + tzinfo) | +6.1 MB | +5.5 MB |
| First parse (regex compilation) | +24.1 MB | +21.9 MB |
| 100 parses (steady state) | +0.0 MB | +0.1 MB |
| **Total over baseline** | **+30.2 MB** | **+27.5 MB** |

### The `.so` in RSS (from `/proc/self/smaps`)

| Segment | Virtual | RSS | % resident |
|---------|---------|-----|------------|
| r--p (headers/rela) | 692 KB | 696 KB | 100% |
| r-xp (text) | 5,276 KB | 3,356 KB | 64% |
| r--p (rodata/eh_frame) | 2,008 KB | 940 KB | 47% |
| rw-p (data.rel.ro/got) | 543 KB | 544 KB | 100% |
| **Total** | **8,517 KB** | **5,536 KB (5.4 MB)** | 65% |

Demand paging leaves 35% of the `.so`'s virtual pages unresident. The text
segment (3.3 MB resident of 5.2 MB mapped) is the largest single chunk.

### The 24 MB first-parse cost

Almost entirely **anonymous heap** (Pss_Anon ~30 MB vs Pss_File ~12 MB).
The Rust `regex` crate compiles 235+ patterns into DFA/bytecode on first
use per locale via `OnceLock`, then intentionally leaks the result via
`Box::leak` (`lang/mod.rs:21`) — the rules are `&'static [Rule]` and are
never reclaimed. This is a one-time cost: subsequent parses add zero memory.
