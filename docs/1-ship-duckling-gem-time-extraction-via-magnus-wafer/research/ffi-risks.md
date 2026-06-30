# FFI Binding Risks — Hypotheses and Test Results

This document evaluates the technical risks of the Magnus + wafer-inc-duckling binding
strategy. Each concern from preliminary Gemini research is treated as a **hypothesis to
test**, not a premise to confirm. For each: what was tested, what was found, whether the
risk is real, and which milestone (if any) should address it.

All benchmarks were run against the compiled release binary of wafer-inc-duckling 0.4.0
on this machine using Criterion. All code observations were from
`/Users/cpb/projects/duks/wafer-inc-duckling` and `/Users/cpb/projects/duks/magnus`.

---

## Summary Table

| Risk | Hypothesis | Verdict | Version |
|------|-----------|---------|---------|
| 1. Incomplete port / maintenance | wafer-inc has meaningful gaps for LLM validation | **FALSE for this use case** — calendar math works through 2030+; but see day-of-week caveat | Inform 0.2.0 README |
| 2. GVL thread blocking | 500µs holds noticeably degrade concurrent Ruby | **PLAUSIBLE** — 505µs measured; Magnus 0.9 has no high-level GVL release API | Benchmark at 0.2.1; fix in 0.3.0 if needed |
| 3. Panic boundary crash | Panics inside duckling crash the Ruby process | **ALREADY MITIGATED** by duckling's own `catch_unwind` in release builds | Code practice for 0.2.0; not architectural |
| 4. GC pressure | Ephemeral Ruby object allocation spikes GC | **UNKNOWN** — plausible at scale; not measurable without profiling at production load | Benchmark at 0.2.1 |
| 5. Date rot (hardcoded 2020–2025 ranges) | 2026+ dates fail or produce wrong results | **FALSE** — tested through 2030; Easter, Christmas, relative dates all correct | No action needed |
| 6. Meta abandonment (Haskell frozen 2021) | Dead parent library blocks progress | **NOT APPLICABLE** — Gemini conflated two different projects; wafer-inc is independent | Monitor |

---

## Risk 1: Incomplete Port and Maintenance

**Hypothesis:** wafer-inc-duckling is an unofficial community port that lacks feature parity
with Meta's Haskell engine, and maintenance burden will block the LLM validation use case.

### What was tested

Ran wafer-inc-duckling 0.4.0 against a set of 2026–2030 date expressions from the LLM
validation use case:

```
"Friday July 1st 2026"    → 2026-07-01T00:00:00 (Day, Naive)
"tomorrow"                → 2026-07-01T00:00:00 (Day, Naive)     ✓ correct for ref 2026-06-30
"next Monday"             → 2026-07-06T00:00:00 (Day, Naive)     ✓ correct (Jun 30 = Tue)
"July 4th 2026"           → 2026-07-04T00:00:00 (Day, Naive)     ✓
"Christmas 2026"          → 2026-12-25T00:00:00 holiday:"christmas"  ✓
"New Year's Day 2027"     → 2027-01-01T00:00:00 holiday:"new year's day"  ✓
"in 2 hours"              → 2026-06-30T14:00:00+00:00 (Minute, Instant)  ✓
"next week"               → 2026-07-06T00:00:00 (Week, Naive)    ✓
"Christmas 2030"          → 2030-12-25T00:00:00 holiday:"christmas"  ✓
"Easter 2030"             → 2030-04-21T00:00:00 holiday:"easter"  ✓ (April 21 is correct)
```

Calendar math, relative expressions, and holiday resolution all work correctly for 2026–2030.
Easter uses the Gregorian Easter algorithm (not hardcoded), so it computes correctly for any
year.

### Critical finding: duckling does NOT validate day-of-week labels

The most important result for the LLM validation use case:

```
Input: "Friday July 1st 2026"
Result: 2026-07-01T00:00:00 (body="Friday July 1st 2026", latent=false)
```

Duckling **resolves the date** (July 1, 2026) but **does not flag** that "Friday" is wrong
(July 1, 2026 is a Wednesday). It treats the day-of-week label as a disambiguation hint for
ambiguous dates rather than a constraint to validate.

This is the exact use case the Gemini discussion highlighted. **The gem alone is insufficient
for day-of-week mismatch detection.** A complete LLM guardrail must:

1. Call `Duckling.parse(text, ...)` to extract the resolved date
2. Independently compute the day of the week: `Date.new(year, month, day).strftime("%A")`
3. Compare against the claimed day-of-week in the original text
4. Flag mismatches as LLM hallucinations

This is a semantic gap in duckling's design, not a missing feature. It applies to the
Haskell original as well.

### Verdict

**The "incomplete port" risk is FALSE for the LLM date validation use case.** Calendar
math, relative expressions, and holidays work correctly through 2030+.

The maintenance risk is also lower than Gemini stated: wafer-inc-duckling is an independent
Rust implementation (not a binding to Meta's Haskell code), published on crates.io as
`duckling 0.4.0` on 2026-04-16. It is not dependent on Meta's frozen 2021 Haskell release
(see Risk 6).

**Action for 0.2.0:** Document the day-of-week validation gap in the README and in the API
examples, so callers understand what the gem does and does not validate.

---

## Risk 2: GVL Thread Blocking

**Hypothesis:** Duckling parsing holds Ruby's GVL (Global VM Lock) long enough that
concurrent Ruby threads — Puma workers, Sidekiq jobs — are meaningfully delayed.

### What was measured

Criterion benchmarks from `benches/parse.rs` in wafer-inc-duckling (release build,
`/Users/cpb/projects/duks/wafer-inc-duckling`):

| Input | Median time |
|-------|-------------|
| `"tomorrow at 3pm"` (short) | **505 µs** |
| `"from 13 to 15 of July"` (medium) | **517 µs** |
| `"meet me next Wednesday at 2:30pm for about 2 hours"` (long) | **2.93 ms** |
| `"the quick brown fox..."` (no match) | **158 µs** |
| `""` (empty) | **12 µs** |

Note: these numbers include only Rust parse time, not the Magnus object conversion overhead.
Real GVL hold time will be somewhat higher once object construction is included.

### What Magnus 0.9 actually provides

Gemini suggested using `ruby.thread_prevent_gvl()` or `magnus::thread::call_without_gvl`
to release the GVL during parsing. **These do not exist in Magnus 0.9.**

From `magnus/src/lib.rs` (lines 1510–1512), the Ruby C API functions for GVL release are
listed as **not wrapped**:

```
// * `rb_thread_call_without_gvl`:   ← not implemented
// * `rb_thread_call_without_gvl2`:  ← not implemented
// * `rb_thread_call_with_gvl`:      ← not implemented
// * `rb_nogvl`:                     ← not implemented (line 1118)
```

Unimplemented entries use `// ` (not `//!`). Implemented entries have `//!` with a
`[Ruby::method_name]` link.

To release the GVL from a Magnus extension today, you must call `rb_sys` unsafe functions
directly. This is non-trivial and bypasses Magnus's safety guarantees.

### Impact analysis

| Scenario | GVL hold | Impact |
|----------|----------|--------|
| Single Puma thread, LLM output validation | ~500 µs | Negligible |
| 8 Puma threads, all parsing simultaneously | ~500 µs each, serialized | Up to 3.5ms worst-case wait |
| Short phrases ("tomorrow") | ~500 µs | Low — typical for native ext calls |
| Long LLM-generated paragraphs | ~3 ms | Noticeable — 3x slower than a typical Ruby context-switch quantum (~1ms) |
| Streaming LLM validation per-chunk | Depends on chunk size | Could block if chunks are large prose |

At low concurrency (1–4 threads) and short inputs, 500µs is acceptable. At higher concurrency
or when passing long prose strings, it degrades meaningful parallelism.

### Verdict

**PLAUSIBLE but not a blocker for 0.2.0.** The risk is real at scale but there is no
Magnus 0.9 high-level API to address it. Options:

- **0.2.0**: Accept GVL hold. Input strings for the LLM validation use case are typically
  short (a few words to a sentence), keeping hold time under 1ms.
- **0.2.1**: Benchmark real GVL impact in a Puma process. Measure before optimizing.
- **0.3.0**: Evaluate (a) waiting for Magnus to implement `rb_thread_call_without_gvl`,
  (b) calling raw `rb_sys::rb_thread_call_without_gvl` via unsafe from within the Magnus
  extension, (c) adopting a worker-thread model where parsing runs in a dedicated Rust
  threadpool and results are delivered via channels.

**Action for 0.2.0:** Document the GVL hold and the input-size boundary where it matters.
Add a note that GVL release is not available in Magnus 0.9.

---

## Risk 3: Panic Boundary Catastrophe

**Hypothesis:** An internal panic in wafer-inc-duckling crosses the FFI boundary and crashes
the Ruby process (segfault or hard abort).

### What was found in the source

From `wafer-inc-duckling/src/lib.rs` (already documented in
[public-functions.md](./wafer-inc-duckling-api/public-functions.md)):

```rust
// In release builds (#[cfg(not(debug_assertions))]):
// parse() wraps the inner parser in catch_unwind, logs any panic via
// log::error!, and returns an empty Vec rather than unwinding the caller.
```

The library already handles this. In release builds (`--release`), panics inside the parser
are caught and the function returns `vec![]`. The Ruby process is not affected.

In debug builds, panics propagate normally. The gem should always be compiled with
`--release` in production (which `rake compile` does by default via `cargo build --release`).

### What the bridge code must still do

The **bridge code** (our `lib.rs`) can still panic if we use `.unwrap()` on fallible
operations. Panics in the bridge code are **not** caught by duckling's `catch_unwind`.
Common unsafe patterns:

```rust
// BAD — panics if locale string is empty or structurally wrong
let lang = locale_str.split('-').next().unwrap();

// GOOD — propagates as Ruby ArgumentError
let lang = locale_str.split('-').next()
    .ok_or_else(|| Error::new(ruby.exception_arg_error(), "empty locale"))?;
```

Gemini's suggestion to add a second `catch_unwind` in the bridge is prudent for bridging
code that calls `.unwrap()`, but it's a code quality concern, not an architectural one.

### Verdict

**ALREADY MITIGATED** by duckling's own `catch_unwind` for the library itself.
**Code practice** for the bridge: use `?` instead of `.unwrap()` throughout bridge code.
Add a `catch_unwind` wrapper in `lib.rs` around the entire `parse` function body as a
belt-and-suspenders measure.

**Action for 0.2.0:** Forbid `.unwrap()` in bridge code. Use `?` everywhere. A single
`catch_unwind` around the bridge `parse` function body (translating panics to
`RuntimeError`) is low-cost and good practice.

```rust
fn parse(ruby: &Ruby, args: &[Value]) -> Result<RArray, Error> {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // ... all parsing logic here ...
    }));
    match result {
        Ok(r) => r,
        Err(_) => Err(Error::new(ruby.exception_runtime_error(),
            "internal duckling panic — this is a bug")),
    }
}
```

---

## Risk 4: GC Pressure from Ruby Object Allocation

**Hypothesis:** Converting Rust structs to Ruby `Hash`/`Array`/`Symbol` objects creates
enough ephemeral allocation that GC spikes neutralize the performance gains from native
parsing.

### What is known

Each entity produces roughly:
- 1 outer `RHash` (~6 key-value pairs)
- 1 value `RHash` (~4 key-value pairs)
- 1 `RArray` for `:values` (1–3 `RHash` entries, each ~3 key-value pairs)
- ~10 `Symbol` keys (interned — no GC pressure after first creation)
- ~5 `String` values (body, ISO8601 datetime — allocated each call)

For a single entity with 1 candidate in `:values`, that's roughly 3 hashes, 1 array,
5 strings, and ~15 interned symbols per call. Interned symbols are never GC'd; strings and
hashes are.

At 100 parses/second, that's ~300 Ruby hashes + ~500 strings per second entering the young
generation heap. For comparison, a single Rails request typically creates thousands of
objects. This is unlikely to be the bottleneck at moderate scale.

At very high throughput (1000+ parses/second), GC pressure could become visible, especially
if parse results are discarded immediately (forcing GC to collect them rapidly).

### Gemini's JSON round-trip suggestion

Gemini suggested serializing to a JSON string in Rust (via `serde_json`) and parsing in Ruby
(via Oj) to eliminate Ruby object allocation in the hot path.

**Why this was rejected in our research:** `serde_json` + serde's default serialization
produces the wrong shape (externally-tagged enums, PascalCase grains). This requires either
upstream serde attribute changes or a custom `Serialize` impl — the same amount of work as
manual Magnus mapping.

**What this would look like with correct serialization:**

If we added a custom `Serialize` impl to produce the target shape, we could return a raw
JSON string and let Ruby's Oj parse it. This would:
- Eliminate all Ruby Hash/Array/Symbol allocation in the bridge
- Add one string allocation (the JSON) + Oj parsing overhead
- Produce a hash with string keys (Oj default) — incompatible with the hill tests (symbol keys)
- Require `Oj.load(json, symbol_keys: true)` to get symbol keys

This is a viable option for a future performance-focused release but requires: (a) a custom
serde `Serialize` impl in the bridge crate, (b) `Oj` as a runtime dependency, (c) updating
hill tests to accept both shapes or picking one.

### Verdict

**UNKNOWN** — plausible at scale, but premature to optimize for 0.2.0. The allocation per
call is small; the bottleneck hypothesis must be verified with profiling before changing the
architecture.

**Action for 0.2.1:** After shipping 0.2.0, add a benchmark that measures end-to-end
`Duckling.parse` call throughput from Ruby (including Magnus conversion overhead) and
measures GC time with `GC.stat`. If GC shows up, evaluate the JSON round-trip approach
with custom serialization as a 0.3.0 alternative API path.

---

## Risk 5: Date Rot (Hardcoded 2020–2025 Ranges)

**Hypothesis:** wafer-inc-duckling has hardcoded holiday ranges or relative-date calculations
that break or produce wrong results for 2026+ dates.

### What was tested

All tested with reference time `2026-06-30T12:00:00+00:00`:

```
"Friday July 1st 2026"  → 2026-07-01 (Day) ✓ date correct; no day-of-week flag (see Risk 1)
"Christmas 2026"        → 2026-12-25 holiday:"christmas" ✓
"New Year's Day 2027"   → 2027-01-01 holiday:"new year's day" ✓
"Christmas 2030"        → 2030-12-25 holiday:"christmas" ✓
"Easter 2030"           → 2030-04-21 holiday:"easter" ✓ (April 21, 2030 is correct per Gregorian)
"December 31 2030"      → 2030-12-31 ✓
"January 1 2031"        → 2031-01-01 ✓
```

Easter uses the Gregorian Easter algorithm (implemented in pure Rust), not a hardcoded table.
Holidays are detected by name matching, not by year range.

### Verdict

**FALSIFIED.** There is no date rot observable in wafer-inc-duckling 0.4.0 for dates through
2031. Calendar arithmetic is fully algorithmic.

**No action needed.**

---

## Risk 6: Meta Abandonment (Haskell Duckling Frozen Since 2021)

**Hypothesis:** Because Meta's Haskell `facebook/duckling` has not had a release since April
2021, the entire ecosystem is stagnant and the Ruby gem is building on quicksand.

### What Gemini got wrong

Gemini conflated two distinct projects:

| Project | Status |
|---------|--------|
| `facebook/duckling` (Haskell) | Last release 2021; effectively frozen |
| `wafer-inc/duckling` (Rust rewrite) | Actively maintained; 0.4.0 published crates.io **2026-04-16** |

wafer-inc-duckling is not a binding to Meta's Haskell binary. It is an independent Rust
reimplementation. Its authors read the Haskell source for rule parity but compile everything
to native Rust. The Meta project being frozen does not prevent wafer-inc from making their
own releases.

### What is true

- wafer-inc/duckling has a single primary maintainer (anchpop). If they lose interest, the
  crate could become stagnant.
- There is no formal governance or company backing the Rust crate.
- The Rust crate may not track every future rule change Meta makes to the Haskell version
  (though Meta hasn't made meaningful changes since 2021 anyway).

For the LLM validation use case (date/time parsing, well-understood grammar rules that don't
change), this is a low-risk dependency: calendar math doesn't need updates.

### Verdict

**NOT APPLICABLE** as stated by Gemini. The maintenance risk exists but is specific to
wafer-inc (not Meta) and is low for a use case that doesn't need new linguistic rules.

**Action:** Monitor `https://github.com/wafer-inc/duckling` for activity. If the crate
becomes unmaintained before we need changes, the existing research in this repo provides
enough context to fork and maintain a subset of the rules.

---

## Version Roadmap for Risk Mitigation

| Milestone | Risk-related action |
|-----------|---------------------|
| **0.2.0** | (1) Document day-of-week gap in README; (2) Use `?` not `.unwrap()` in bridge; add `catch_unwind` wrapper; (3) Note GVL hold and input-size boundary in README |
| **0.2.1** | Benchmark real throughput with Ruby GC stats at simulated load; measure GVL hold with timing from Ruby |
| **0.3.0** | If 0.2.1 shows GVL issues: evaluate unsafe `rb_sys::rb_thread_call_without_gvl` wrapper or Magnus update; if GC shows up: evaluate JSON round-trip with custom serialization |
| **1.0** | Decide on upstream serde attribute PR to wafer-inc/duckling that would unlock Option A (serde_magnus) and eliminate manual mapping |
| **Monitor** | wafer-inc/duckling maintenance activity; Magnus GVL release API landing |

---

## Appendix: The Gemini Code Sample Analysis

Gemini proposed a "defensive" implementation pattern with three features:

```rust
// Gemini's suggestion:
ruby.thread_prevent_gvl(move || {          // ← DOES NOT EXIST in Magnus 0.9
    catch_unwind(|| {
        let results = parse(...);
        serde_json::to_string(&results)... // ← produces wrong shape without custom impl
    })
})
```

**`ruby.thread_prevent_gvl`**: Not in Magnus 0.9 API. Listed as unimplemented in
`magnus/src/lib.rs`.

**`catch_unwind`**: Valid and useful, but duckling already does this in release builds.
Adding it to the bridge is belt-and-suspenders, not a required fix.

**`serde_json` return**: Valid approach for reducing GC pressure, but produces wrong shapes
(see Risk 4). Would require a custom `Serialize` impl.

The defensive pattern Gemini describes is directionally correct as a 0.3.0 goal, but
overstated as a 0.2.0 prerequisite, and it is not directly implementable in Magnus 0.9
without raw rb_sys calls.
