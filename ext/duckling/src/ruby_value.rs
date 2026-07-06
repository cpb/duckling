use magnus::r_hash::ForEach;
use magnus::value::ReprValue;
use magnus::{Error, RArray, RHash, Ruby, TryConvert, Value};

/// Recursively rewrites every `Hash` reachable from `value` (including
/// through `Array` elements, at any depth) so its keys are `Symbol`s instead
/// of `String`s, mutating in place rather than allocating replacement
/// Hashes/Arrays. Keys that aren't `String` (e.g. already a `Symbol`) pass
/// through unchanged; non-Hash, non-Array values are untouched.
///
/// This is deliberately an in-place rewrite rather than a recursive rebuild:
/// `serde_magnus::serialize`'s externally-tagged output already allocates one
/// Hash per enum layer (e.g. `{"Naive" => {...}}`), so a rebuild pass would
/// double that cost by discarding and reallocating the whole tree just to
/// change key types.
///
/// GC safety note: keys collected off the `Hash` are staged in a Ruby
/// `RArray`, never a Rust-native `Vec<Value>`. A `Value` held only in a
/// `Vec` (heap-allocated Rust memory) is invisible to MRI's conservative
/// stack-scanning GC once it's no longer reachable from any Ruby-visible
/// root — deleting an entry from its `Hash` and stashing the freed key/value
/// `Value`s in a `Vec` across further Magnus calls (which can trigger GC) is
/// a real use-after-free, not just a style concern. Keeping them in an
/// `RArray` instead means the GC treats them as reachable for as long as
/// the array itself is reachable (it lives in a local, stack-scanned
/// `RArray` variable for the duration of this function).
pub fn symbolize_keys_in_place(ruby: &Ruby, value: Value) -> Result<(), Error> {
    if let Some(hash) = RHash::from_value(value) {
        let keys = ruby.ary_new();
        hash.foreach(|k: Value, _v: Value| {
            keys.push(k)?;
            Ok(ForEach::Continue)
        })?;

        for i in 0..keys.len() as isize {
            let k: Value = keys.entry(i)?;
            let v: Value = hash.delete(k)?;
            symbolize_keys_in_place(ruby, v)?;
            let key = match String::try_convert(k) {
                Ok(s) => ruby.to_symbol(s.as_str()).as_value(),
                Err(_) => k,
            };
            hash.aset(key, v)?;
        }
        return Ok(());
    }

    if let Some(arr) = RArray::from_value(value) {
        for i in 0..arr.len() as isize {
            let item: Value = arr.entry(i)?;
            symbolize_keys_in_place(ruby, item)?;
        }
    }

    Ok(())
}

/// Serializes `input` via `serde_magnus`, strips serde's externally-tagged
/// single-key wrapper (e.g. `{"Numeral" => 42.0}` → `42.0`,
/// `{"Url" => {"value" => ..., "domain" => ...}}` → symbol-keyed inner Hash),
/// and symbolizes every Hash key in the returned payload. The discarded tag
/// is redundant with the entity-level `:dim` key, which is computed
/// independently via `DimensionValue::dim_kind()`.
///
/// If the serialized value is not a single-key Hash (unreachable for every
/// externally-tagged enum duckling 0.4.0 serializes today; reachable only if
/// a future crate version changes its serde representation), this does not
/// raise: the whole value is symbolized and returned verbatim. A shape drift
/// shouldn't turn an otherwise-successful parse into an exception, and the
/// raw tagged shape is strictly more debuggable than a lost result — the
/// per-dimension tests pin the expected shapes and will catch such drift at
/// upgrade time.
///
/// GC safety: every intermediate `Value` (`serialized`, the `[key, value]`
/// pair, `payload`) lives in a stack-scanned local, and nothing is deleted
/// from the outer hash before the payload is returned — see
/// `symbolize_keys_in_place`'s note for why heap-held `Vec<Value>`s are the
/// thing to avoid.
pub fn serialize_unwrapped<T>(ruby: &Ruby, input: &T) -> Result<Value, Error>
where
    T: serde::Serialize + ?Sized,
{
    let serialized: Value = serde_magnus::serialize(ruby, input)?;

    if let Some(hash) = RHash::from_value(serialized) {
        if hash.len() == 1 {
            let pair: RArray = hash.funcall("first", ())?;
            let payload: Value = pair.entry(1)?;
            symbolize_keys_in_place(ruby, payload)?;
            return Ok(payload);
        }
    }

    symbolize_keys_in_place(ruby, serialized)?;
    Ok(serialized)
}
