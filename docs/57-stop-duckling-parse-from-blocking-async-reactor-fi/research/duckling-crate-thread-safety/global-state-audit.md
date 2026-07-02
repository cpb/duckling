# Global Mutable State Audit

A search of every source file under `src/` in
[duckling](https://github.com/wafer-inc/duckling) at commit
[`c96b068`](https://github.com/wafer-inc/duckling/tree/c96b0681ab9a097712b20fe838786a2c65efc537)
for `static mut`, `thread_local!`, `lazy_static!`, `RefCell`, `Cell`, and
`unsafe` finds **none** anywhere in the crate. All process-wide mutable
state is exactly three caches, each `Mutex`- or `OnceLock`-guarded. This is
a stronger/more complete finding than a prior pass over this crate had
established: that pass covered the first two caches below; this audit adds
the third (a ranking-classifier cache) and confirms exhaustively (via
`grep -rn` over the full `src/` tree, not just the files that seemed
relevant) that no other global state exists.

## The three caches

### 1. Regex-set cache (`engine.rs`)

```rust
/// Global cache of RegexSets, keyed by rules slice pointer.
/// Safe because rules are `&'static [Rule]` (leaked by `lang::rules_for`).
static REGEX_SET_CACHE: Lazy<Mutex<HashMap<usize, &'static CachedRegexSet>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
```
— [`engine.rs#L57-L60`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/engine.rs#L57-L60)

Populated by `get_or_build_regex_set`
([`engine.rs#L62-L95`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/engine.rs#L62-L95)):

```rust
fn get_or_build_regex_set(rules: &[Rule]) -> &'static CachedRegexSet {
    let key = rules.as_ptr() as usize;
    {
        let cache = REGEX_SET_CACHE.lock().unwrap();
        if let Some(cached) = cache.get(&key) {
            return cached;
        }
    }
    // ... build `cached: &'static CachedRegexSet` outside the lock ...
    REGEX_SET_CACHE.lock().unwrap().insert(key, cached);
    cached
}
```

Lock is held only for the lookup (dropped at the end of the inner block
before building) and again briefly for the insert. Building the `RegexSet`
happens with no lock held. This is a classic double-checked-cache pattern:
under a race, two threads can both miss the cache and both build+leak a
`CachedRegexSet` for the same key, with the second `insert` silently
overwriting the first in the map (the first leaked value is never freed —
harmless since it was already `Box::leak`ed and unreachable, not unsound,
just a wasted allocation). Every subsequent access from either thread
returns a valid, fully-built `&'static CachedRegexSet` either way — never a
torn/partial one.

### 2. Rule cache (`lang/mod.rs`)

```rust
pub fn rules_for(locale: Locale, dims: &[DimensionKind]) -> &'static [Rule] {
    let cache = rule_cache();
    let key = CacheKey::new(locale.lang, locale.region, dims);

    if let Some(rules) = cache.lock().unwrap().get(&key).copied() {
        return rules;
    }

    let built = build_rules(locale, dims);
    let leaked: &'static [Rule] = Box::leak(built.into_boxed_slice());

    let mut guard = cache.lock().unwrap();
    guard.entry(key).or_insert(leaked)
}
```
— [`lang/mod.rs#L12-L25`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/lang/mod.rs#L12-L25)

backed by

```rust
fn rule_cache() -> &'static Mutex<HashMap<CacheKey, &'static [Rule]>> {
    static CACHE: OnceLock<Mutex<HashMap<CacheKey, &'static [Rule]>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}
```
— [`lang/mod.rs#L47-L50`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/lang/mod.rs#L47-L50)

Same shape as the regex-set cache: brief lock for lookup, build unlocked,
brief lock for insert (here using `entry().or_insert()`, so a losing racer
gets back whichever `&'static [Rule]` actually landed in the map rather than
its own redundant build — slightly tighter than the regex-set cache, but
the difference is immaterial to soundness either way).

### 3. Ranking-classifier cache (`ranking/mod.rs`) — not previously documented

```rust
fn classifiers_for_locale(locale: &Locale) -> &'static Classifiers {
    static EN_XX: OnceLock<Classifiers> = OnceLock::new();
    static AR_XX: OnceLock<Classifiers> = OnceLock::new();
    static EL_XX: OnceLock<Classifiers> = OnceLock::new();
    static ES_XX: OnceLock<Classifiers> = OnceLock::new();
    static PT_XX: OnceLock<Classifiers> = OnceLock::new();
    static TR_XX: OnceLock<Classifiers> = OnceLock::new();
    static EMPTY: OnceLock<Classifiers> = OnceLock::new();

    fn load(json: &str) -> Classifiers { /* parses an embedded classifier JSON blob */ }

    match locale.lang {
        Lang::EN => EN_XX.get_or_init(|| load(include_str!("../ranking_classifiers/en_xx.json"))),
        // ... AR, EL, ES, PT, TR ...
        _ => EMPTY.get_or_init(HashMap::new),
    }
}
```
— [`ranking/mod.rs#L268-L312`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/ranking/mod.rs#L268-L312),
`Classifiers` = `pub type Classifiers = HashMap<String, Classifier>` at
[`ranking/mod.rs#L84`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/ranking/mod.rs#L84).

This is a lazily-initialized, per-language `OnceLock<Classifiers>` — one
static per supported ranking-classifier language (`EN`, `AR`, `EL`, `ES`,
`PT`, `TR`), plus an `EMPTY` fallback for languages without a trained
classifier. `OnceLock::get_or_init` is specifically designed for exactly
this concurrent-first-access pattern: if two threads call it simultaneously
for the same static, one blocks until the other's initializer
(`load(...)`, which parses an `include_str!`-embedded JSON blob compiled
into the binary — pure, deterministic, no I/O) finishes, then both get the
same `&'static Classifiers`. No possibility of a torn read, no possibility
of two different `Classifiers` maps for the same language coexisting. This
is arguably the *simplest* of the three caches to reason about — there is
no manual lock/lookup/insert sequence to audit, `OnceLock` encodes the
correct behavior in its type.

## Why brief locks don't reintroduce blocking

All three caches only hold their lock for a cheap `HashMap`
lookup/insert (or, for `OnceLock`, only block during first-ever
initialization per key) — never across a full `parse()` call, which is the
expensive part (regex matching, node composition, resolution, ranking).
Once GVL release lets multiple Ruby threads call into `duckling::parse`
concurrently, those calls will only ever contend with each other on these
microsecond-scale cache operations, not serialize on each other's full
parse duration. In practice, after the first call for a given
(locale, dims) / rule-slice / language combination populates its cache
entry, all later calls for that combination are lock-and-return-immediately
on the fast path.

## Send + Sync verification

### Trait-object function pointers are explicitly bounded

```rust
pub(crate) type Predicate = Box<dyn Fn(&TokenData) -> bool + Send + Sync>;
pub(crate) type Production = Box<dyn Fn(&[&Node]) -> Option<TokenData> + Send + Sync>;
```
— [`types.rs#L427-L428`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/types.rs#L427-L428)

These back every `Rule`'s pattern-match predicate and node-production
closure. Because the bound is part of the type alias itself, every `Rule`
built anywhere in the crate is guaranteed `Send + Sync` — the compiler
would refuse to compile a `Rule` construction that captured something
thread-unsafe in its predicate/production closures. This is what makes it
sound for `&'static [Rule]` to be leaked once and then read concurrently
from any thread (the premise the two `&'static`-returning caches above
depend on).

### Public data types are plain, `Copy`/`Clone` data with no interior mutability

- `Context` — `{ reference_time: DateTime<FixedOffset>, locale: Locale }`,
  `#[derive(Debug, Clone)]`, `impl Default` seeds it from `Utc::now()`.
  [`resolve.rs#L8-L15`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/resolve.rs#L8-L15)
- `Options` — `{ with_latent: bool }`,
  `#[derive(Debug, Clone, Default)]`.
  [`resolve.rs#L79-L83`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/resolve.rs#L79-L83)
- `Locale` — `{ lang: Lang, region: Option<Region> }`,
  `#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]`;
  `Lang`/`Region` are themselves plain
  `#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]` enums.
  [`locale.rs#L183-L190`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/locale.rs#L183-L190)
- `Entity` (the public return type) —
  `{ body: String, start: usize, end: usize, value: DimensionValue, latent: Option<bool> }`,
  `#[derive(Debug, Clone, PartialEq, serde::Serialize)]`. No `Rc`/`RefCell`
  in `Entity` or (transitively) `DimensionValue`.
  [`types.rs#L479-L492`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/types.rs#L479-L492)

None of these carry `Rc`, `RefCell`, `Cell`, raw pointers, or any other
`!Send`/`!Sync` primitive — they're auto-`Send`/`Sync` by the compiler's
default rules for plain aggregate data. `chrono`'s `DateTime<FixedOffset>`
is itself `Send + Sync` (it holds no thread-affine state).

### The crate's only `Rc` usage stays entirely local to one call

```rust
#[derive(Debug, Clone)]
pub(crate) struct Node {
    pub(crate) range: Range,
    pub(crate) token_data: TokenData,
    pub(crate) children: Vec<Rc<Node>>,
    pub(crate) rule_name: Option<String>,
}
```
— [`types.rs#L408-L414`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/types.rs#L408-L414)

`grep -rln "Rc<"` over `src/` finds exactly two files reference `Rc`:
`types.rs` (the `Node.children` field above) and `engine.rs` (which
constructs/traverses `Node` trees during parsing). The `Node` type is
`pub(crate)` — it never appears in the crate's public API. It's held by
`Stash`, also entirely local:

```rust
pub struct Stash {
    nodes: BTreeMap<usize, Vec<Node>>,
    count: usize,
}
```
— [`stash.rs#L6-L9`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/stash.rs#L6-L9)

`engine::parse_string` constructs a fresh `Stash::new()` on every call
(`let mut stash = Stash::new();`) and it — along with every `Node`/`Rc<Node>`
inside it — is owned entirely within that single call's stack frame. The
public `parse`/`parse_inner` pipeline in `lib.rs` converts `Stash` contents
into `ResolvedToken`s and finally into the public, `Rc`-free `Entity` type
before returning; no `Rc<Node>` (or anything referencing one) crosses the
`parse()` return boundary or gets stored anywhere static. Since `Rc<Node>`
is never shared across threads and never outlives a single call, its
`!Sync`-ness is immaterial to the concurrent-calls-from-multiple-threads
question this doc addresses.

## Conclusion for this document

Every piece of global mutable state in the crate is cache-shaped,
`Mutex`/`OnceLock`-guarded, and lock-held only briefly relative to a full
parse. Every type that crosses the public API or gets leaked to `'static`
is `Send + Sync` by construction or derivation. The crate's one non-`Send`
type never leaves a single call. Concurrent calls to `duckling::parse` from
multiple threads are memory-safe and data-race-free.
