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
