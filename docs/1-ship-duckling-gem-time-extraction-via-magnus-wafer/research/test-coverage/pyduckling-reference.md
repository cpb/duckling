# pyduckling Reference Tests

Source examined: [`duckling/tests/test_duckling.py`](https://github.com/cpb/pyduckling/blob/bbe06d2deb75d556cf324fe5e4edc04962e7192f/duckling/tests/test_duckling.py) (171 lines)

pyduckling is a Python FFI wrapper around the **Haskell** duckling binary (`hs_init` / GHC runtime). It is NOT the same codebase as [duckling](https://github.com/wafer-inc/duckling) (which is a Rust port). Both aim to be compatible with the Haskell original, but they are independent implementations.

---

## 1. pyduckling Test Inventory

The test file contains 8 test functions:

| Function | What it tests |
|---|---|
| `test_load_time_zones` | `load_time_zones("/usr/share/zoneinfo")` returns non-None |
| `test_get_current_ref_time` | `get_current_ref_time(tzdb, tz_name)` returns ISO8601 encoding current time in given TZ; fallback to UTC when TZ unknown |
| `test_parse_ref_time` | `parse_ref_time(tzdb, tz_name, unix_ts)` round-trips a Unix timestamp through a timezone; verifies UTC equivalence |
| `test_parse_lang` | `parse_lang("es")` → Lang with `.name == "ES"`; case-insensitive; unknown lang falls back to `"EN"` |
| `test_default_locale_lang` | `default_locale_lang(lang_es)` → Locale with `.name == "ES_XX"` |
| `test_parse_locale` | `parse_locale("ES_CO", default_locale)` → Locale `"ES_CO"`; `parse_locale("CO", default_locale)` → fallback `"ES_XX"` |
| `test_parse_dimensions` | 14 valid dimension strings parse correctly; invalid strings are silently dropped |
| `test_parse` | End-to-end: Spanish time + distance + volume parsing |

### `test_parse_dimensions` — the 14 valid dimensions

```python
valid_dimensions = [
    "amount-of-money", "credit-card-number", "distance",
    "duration", "email", "number", "ordinal",
    "phone-number", "quantity", "temperature",
    "time", "time-grain", "url", "volume"
]
output_dims = parse_dimensions(valid_dimensions)
assert len(output_dims) == len(valid_dimensions)  # 14

invalid_dimensions = ["amount-of-money", "dim1", "credit-card-number", "dim2", "distance", "dim3"]
output_dims = parse_dimensions(invalid_dimensions)
assert len(output_dims) == len(invalid_dimensions) - 3  # 3 valid, 3 dropped
```

This reveals: invalid dimension names are **silently dropped** (no exception). The 14 valid strings map to the supported dimension kinds.

### `test_parse` — end-to-end

```python
context = Context(ref_time, locale)   # locale = ES_CO
dimensions = ['time', 'duration']
dims = parse_dimensions(dimensions)

result = parse('En dos semanas', context, dims, False)  # with_latent=False
next_time = result[0]['value']['value']
next_time = pendulum.parse(next_time)
expected = ny_now.add(weeks=2).start_of('day')
assert next_time == expected
```

Key observations:
- `parse(text, context, dims, with_latent)` — 4-argument call signature
- Return value is a list of dicts with `dict["value"]["value"]` = ISO8601 datetime string
- The ISO8601 string is timezone-aware (includes offset)
- `with_latent=False` is the 4th argument (not a keyword arg in pyduckling)
- The result datetime is compared as a timezone-aware pendulum datetime

The Spanish phrase "En dos semanas" = "In two weeks" — demonstrates non-English locale support, which is out of scope for Ruby 0.2.0.

### `test_parse_lang` — language fallback

```python
lang_es = parse_lang('es')      # case-insensitive, returns Lang(name="ES")
lang_pt = parse_lang('PT')      # returns Lang(name="PT")
lang_any = parse_lang('UU')     # unknown → falls back to Lang(name="EN")
```

This fallback behavior ("unknown language → EN") should be replicated in the Ruby API.

---

## 2. Infrastructure pyduckling Uses (NOT to Port)

### Timezone database loading

```python
tzdb = load_time_zones("/usr/share/zoneinfo")
```

pyduckling needs to load the system TZ database because the Haskell GHC runtime requires it for timezone-aware reference time construction. [duckling](https://github.com/wafer-inc/duckling) does NOT require this: the Rust `Context` takes a `DateTime<FixedOffset>` directly — there is no TZ database lookup at parse time.

**Do not port**: `test_load_time_zones`, `test_get_current_ref_time`, `test_parse_ref_time`. These test pyduckling-specific infrastructure that has no equivalent in the Ruby/Rust gem.

### `parse_ref_time(tzdb, tz_name, unix_ts)` pattern

pyduckling constructs a reference time as:
```python
ref_time = parse_ref_time(time_zones, 'America/New_York', ny_now.int_timestamp)
```

The Ruby gem will construct reference time differently — either as a Ruby `Time` object or a Unix timestamp paired with a UTC offset. No TZ database name lookup needed.

### Haskell GHC runtime initialization

pyduckling's C extension calls `hs_init()` at load time. The Ruby gem uses a Rust native extension via Magnus — no Haskell runtime, no `hs_init`. This is a primary motivation for the project (see [issue #1](https://github.com/cpb/duckling/issues/1)).

### `pendulum` library

pyduckling tests use the `pendulum` Python library for timezone-aware datetime comparison. Ruby tests use the stdlib `Time` class. No pendulum equivalent needed.

---

## 3. What to Port from pyduckling

### 3a. Dimension string mapping (14 valid names)

Port `test_parse_dimensions` behavior:

```ruby
class TestDucklingDimensions < Minitest::Test
  VALID_DIMS = %w[
    amount-of-money credit-card-number distance
    duration email number ordinal
    phone-number quantity temperature
    time time-grain url volume
  ].freeze

  def test_valid_dimensions_accepted
    # All 14 valid names should be recognized
    # (Behavior: they map to enum values without error)
    results = Duckling.parse("hello", locale: "en",
                             reference_time: REFERENCE_TIME, dims: VALID_DIMS)
    assert_kind_of Array, results  # no exception raised
  end

  def test_invalid_dimensions_silently_dropped
    mixed = ["time", "invalid-dim-xyz", "number"]
    # Should not raise; unknown names are silently ignored
    assert_nothing_raised do
      Duckling.parse("42", locale: "en",
                    reference_time: REFERENCE_TIME, dims: mixed)
    end
  end
end
```

Note: In [duckling](https://github.com/wafer-inc/duckling)'s integration tests, the `Options::default()` does not filter dims — `DimensionKind` is a Rust enum and invalid strings are a type error at compile time. In the Ruby bridge, string-to-enum conversion will happen at runtime, and the behavior for unknown strings (raise vs. drop) must be decided by the bridge author. The pyduckling behavior is to silently drop.

### 3b. `with_latent=false` default behavior

```ruby
def test_with_latent_defaults_to_false
  # By default, latent entities are excluded
  results = Duckling.parse("at 3", locale: "en",
                           reference_time: REFERENCE_TIME, dims: ["time"])
  # If any result is present, none should be latent
  results.each { |e| assert_equal false, e["latent"] }
end
```

### 3c. `with_latent=true` includes additional results

```ruby
def test_with_latent_true
  # Latent option must be passable and not raise
  results = Duckling.parse("at 3", locale: "en",
                           reference_time: REFERENCE_TIME, dims: ["time"],
                           with_latent: true)
  assert_kind_of Array, results
end
```

### 3d. Language fallback behavior

```ruby
def test_unknown_locale_falls_back_to_en
  # pyduckling: parse_lang("UU") → EN
  # Ruby: unknown locale string should either raise ArgumentError or silently use EN
  result = begin
    Duckling.parse("today", locale: "zz", reference_time: REFERENCE_TIME, dims: ["time"])
  rescue ArgumentError
    :raised
  end
  # Either behavior is acceptable — document which the bridge chooses
  assert(result == :raised || result.is_a?(Array))
end
```

### 3e. Basic time parse structure (value format)

Port the structural assertion from `test_parse`:

```ruby
def test_parse_returns_value_hash
  results = Duckling.parse("tomorrow", locale: "en",
                           reference_time: REFERENCE_TIME, dims: ["time"])
  assert_equal 1, results.length
  entity = results.first
  assert entity.key?("body"),  "entity must have 'body' key"
  assert entity.key?("value"), "entity must have 'value' key"
  assert entity.key?("start"), "entity must have 'start' key"
  assert entity.key?("end"),   "entity must have 'end' key"
  v = entity["value"]
  assert v.key?("grain"), "value must have 'grain' key"
  assert v.key?("value"), "value must have 'value' key"
  assert_equal "tomorrow", entity["body"]
end
```

---

## 4. Known Differences: Haskell Duckling vs. wafer-inc-duckling

From reading [duckling](https://github.com/wafer-inc/duckling) README and `src/corpus/time_en.rs`:

### Acknowledgement from README

> "This is a Rust rewrite of facebook/duckling, originally written in Haskell."

No explicit list of divergences is documented in the README.

### What the corpus says

The comment at the top of `tests/time_corpus.rs` (line 3) reads:
> `// All expected values from Haskell corpus at /tmp/duckling-haskell/Duckling/Time/EN/Corpus.hs`

This confirms the [duckling](https://github.com/wafer-inc/duckling) test suite was authored by comparing against the Haskell corpus output. The intent is parity with Haskell.

The comment at line 1 of `time_en.rs`:
> `/// English time training corpus, ported from Duckling/Time/EN/Corpus.hs.`

### Practical implications for Ruby tests

- For simple cases (today, tomorrow, at 3pm, in 2 hours), [duckling](https://github.com/wafer-inc/duckling) and pyduckling should return identical results.
- The Ruby acceptance criteria ([issue #1](https://github.com/cpb/duckling/issues/1)) explicitly says: "matching what [duckling](https://github.com/wafer-inc/duckling) produces" — so Ruby tests compare against the Rust output, not the Haskell/pyduckling output.
- For edge cases (unusual timezone handling, very far-future dates, BC years), divergence is possible. The Ruby test suite should not include edge cases unless the exact expected value has been verified against the [duckling](https://github.com/wafer-inc/duckling) Rust binary.

### Specific known scope difference

[duckling](https://github.com/wafer-inc/duckling)'s English corpus covers holiday logic (`datetime_holiday`) with the same datetime check as regular dates. pyduckling does not have tests for holidays. This is a potential divergence area for future 0.3.0+ testing.

---

## 5. Summary: Port vs. Skip

| pyduckling test | Port to Ruby? | Reason |
|---|---|---|
| `test_load_time_zones` | No | TZ database not needed in Rust bridge |
| `test_get_current_ref_time` | No | Fixed reference time used instead |
| `test_parse_ref_time` | No | No `parse_ref_time()` equivalent in Ruby gem |
| `test_parse_lang` | Partial | Port language fallback behavior only |
| `test_default_locale_lang` | No | Locale object internals differ |
| `test_parse_locale` | No | Locale string format may differ |
| `test_parse_dimensions` | Yes | Port: valid 14 names accepted, invalid dropped |
| `test_parse` (structure) | Yes | Port: value hash shape, `with_latent` behavior |
| `test_parse` (distance/volume) | No | Out of scope for 0.2.0 (time only) |
