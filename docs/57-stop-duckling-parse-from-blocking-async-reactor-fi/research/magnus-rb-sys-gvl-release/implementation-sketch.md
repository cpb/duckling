# Illustrative Sketch: Releasing the GVL Around `duckling::parse`

This is a fenced-code-block sketch only — **not** real `ext/duckling/src/*.rs`
content, and not written into the actual crate as part of this docs-only PR.
It maps the existing `parse` function's before/during/after structure (see
`ext/duckling/src/lib.rs`, current lines 28–64) onto the raw
`rb_thread_call_without_gvl` FFI documented in
[The Raw `rb_thread_call_without_gvl` FFI Surface](raw-ffi-signature.md).

## Today's structure, for reference

```rust
fn parse(ruby: &Ruby, args: &[Value]) -> Result<RArray, Error> {
    // BEFORE — Ruby Value access, builds owned Rust values
    let args = scan_args::scan_args::<(String,), (), (), (), _, ()>(args)?;
    let kw = scan_args::get_kwargs::<_, (), (Option<String>, Option<Vec<String>>, Option<i64>, Option<bool>), ()>(
        args.keywords, &[], &["locale", "dims", "reference_time", "with_latent"],
    )?;
    let text = args.required.0;
    let (locale_str, dims_strs, ref_time_i, with_latent) = kw.optional;
    // ... defaulting + parse_locale / parse_dims / build_context validation ...
    let locale = parse_locale(ruby, &locale_str)?;
    let dims = parse_dims(ruby, &dims_strs)?;
    let context = build_context(ruby, ref_time_i)?;
    let options = Options { with_latent };

    // DURING — the blocking call, touches zero Ruby Values
    let entities = duckling_parse(&text, &locale, &dims, &context, &options);

    // AFTER — Ruby Value construction from the owned Vec<Entity> result
    let out = ruby.ary_new();
    for e in &entities {
        out.push(entity_to_ruby(ruby, e)?)?;
    }
    Ok(out)
}
```

## Sketch: the same structure with the GVL released around DURING

```rust
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Everything the off-GVL callback needs, and everything it produces.
/// Deliberately holds only fully-owned Rust data — no `magnus::Value`, no
/// `magnus::Error`, no other Ruby-VM-touching type crosses this struct in
/// either direction. See raw-ffi-signature.md's panic-safety section for
/// why the error slot is a plain `String` rather than a `magnus::Error`.
struct ParsePayload {
    // -- in: identical to what `duckling_parse` already takes today --
    text: String,
    locale: Locale,
    dims: Vec<DimensionKind>,
    context: Context,
    options: Options,
    // -- out: populated by `parse_without_gvl` before it returns --
    result: Option<Result<Vec<Entity>, String>>,
}

/// The raw callback handed to `rb_thread_call_without_gvl` as `func`. Runs
/// with the GVL released: per the C API's warning, no Ruby method calls, no
/// `Value`/`RArray` construction, no `magnus::Error` construction or
/// raising is permitted here — only the plain Rust computation and writing
/// plain Rust data back into `*payload`.
///
/// Signature matches the bindgen-generated `func` parameter type exactly
/// (verified against this repo's own generated bindings — see
/// raw-ffi-signature.md): `unsafe extern "C" fn(*mut c_void) -> *mut c_void`.
unsafe extern "C" fn parse_without_gvl(payload: *mut c_void) -> *mut c_void {
    let payload = &mut *(payload as *mut ParsePayload);

    let outcome = catch_unwind(AssertUnwindSafe(|| {
        duckling_parse(
            &payload.text,
            &payload.locale,
            &payload.dims,
            &payload.context,
            &payload.options,
        )
    }));

    payload.result = Some(match outcome {
        Ok(entities) => Ok(entities),
        Err(panic_payload) => Err(panic_message(&panic_payload)),
    });

    // Return value is unused by our caller (we read the real result back
    // out of `*payload`); the C API just requires we return *something*.
    std::ptr::null_mut()
}

/// Small helper mirroring duckling's own panic_payload_message downcast
/// (`&str` / `String` / fallback), kept local since we don't have access
/// to duckling's private helper.
fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(&s) = payload.downcast_ref::<&'static str>() {
        s.to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "duckling::parse panicked".to_string()
    }
}

fn parse(ruby: &Ruby, args: &[Value]) -> Result<RArray, Error> {
    // BEFORE — unchanged from today: all Value access, still GVL-held
    let args = scan_args::scan_args::<(String,), (), (), (), _, ()>(args)?;
    let kw = scan_args::get_kwargs::<_, (), (Option<String>, Option<Vec<String>>, Option<i64>, Option<bool>), ()>(
        args.keywords, &[], &["locale", "dims", "reference_time", "with_latent"],
    )?;
    let text = args.required.0;
    let (locale_str, dims_strs, ref_time_i, with_latent) = kw.optional;
    let locale = parse_locale(ruby, &locale_str.unwrap_or_else(|| "en".to_string()))?;
    let dims = parse_dims(ruby, &dims_strs.unwrap_or_else(|| vec!["time".to_string()]))?;
    let context = build_context(ruby, ref_time_i)?;
    let options = Options { with_latent: with_latent.unwrap_or(false) };

    // DURING — box the owned inputs, release the GVL, call duckling::parse,
    // reacquire the GVL (rb_thread_call_without_gvl blocks until it does,
    // per point 4 of its documented behavior — see raw-ffi-signature.md).
    let boxed = Box::new(ParsePayload {
        text,
        locale,
        dims,
        context,
        options,
        result: None,
    });
    let payload_ptr = Box::into_raw(boxed) as *mut c_void;

    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(parse_without_gvl),
            payload_ptr,
            None,                 // ubf: no cancellation hook — see README's Open follow-ups
            std::ptr::null_mut(), // data2: unused without a ubf
        );
    }

    // Reclaim ownership now that we're back on the GVL. This is the only
    // place the payload is freed — the callback above never frees it.
    let boxed = unsafe { Box::from_raw(payload_ptr as *mut ParsePayload) };
    let entities = match boxed.result.expect("callback always sets result before returning") {
        Ok(entities) => entities,
        Err(message) => {
            // Safe to construct/raise now: the GVL is confirmed held again.
            return Err(Error::new(
                ruby.exception_fatal(),
                format!("duckling::parse panicked: {message}"),
            ));
        }
    };

    // AFTER — unchanged from today: builds the Ruby RArray, GVL-held
    let out = ruby.ary_new();
    for e in &entities {
        out.push(entity_to_ruby(ruby, e)?)?;
    }
    Ok(out)
}
```

## What changed, and what didn't

- **Unchanged:** the BEFORE block (arg parsing/validation) and AFTER block
  (`RArray` construction via `entity_to_ruby`) are copied essentially
  verbatim from today's `parse`. Neither one needs to change shape — they
  already only touch Ruby `Value`s while the GVL is guaranteed held, which
  remains true in this sketch.
- **New:** a `ParsePayload` struct to carry owned inputs in and an owned
  `Result<Vec<Entity>, String>` out across the FFI boundary, a raw
  `extern "C"` callback (`parse_without_gvl`) to run inside
  `rb_thread_call_without_gvl`, and the `Box::into_raw`/`Box::from_raw`
  pair to move ownership across it safely.
- **Moved:** the single line `duckling_parse(&text, &locale, &dims,
  &context, &options)` moves from directly inside `parse` into the
  callback, wrapped in `std::panic::catch_unwind` (not
  `magnus::rb_sys::catch_unwind` — see raw-ffi-signature.md for why the
  sketch uses the `std` version directly and defers `magnus::Error`
  construction until after the GVL is reacquired).
- **New failure mode to handle:** where today a panic inside
  `duckling_parse` is caught only by Magnus's outer `function!` wrapper
  (via `RubyFunctionCAry::call_handle_error`'s `catch_unwind`, which never
  sees inside the off-GVL callback), this sketch adds an explicit,
  unconditional (not `debug_assertions`-gated) panic guard around the call
  and turns a caught panic into a normal `Err(magnus::Error)` return from
  `parse` — a `FatalError`-class Ruby exception, matching the severity
  Magnus's own automatic panic-to-`Error` conversion already uses today.

## Things intentionally left out of scope for this sketch

- **`UnwindSafe`**: `duckling::parse`'s own internal use of `catch_unwind`
  wraps its call in `AssertUnwindSafe` (see raw-ffi-signature.md); the
  sketch above does the same for consistency, since `&Locale`/`&Context`/
  etc. references captured by the closure may or may not satisfy
  `UnwindSafe` automatically depending on their internal composition — this
  should be confirmed against a real `cargo build` once implemented, not
  assumed from this sketch alone.
- **Benchmarking** whether the GVL-release/reacquire overhead is worth
  paying for a ~500µs–3ms call — flagged as an open follow-up in
  [Releasing the GVL Around `duckling::parse` with Magnus + rb-sys](README.md).
- **A real `ubf`** for `Thread#raise`/`Thread#kill` cancellation — also
  flagged as an open follow-up in [Releasing the GVL Around `duckling::parse` with Magnus + rb-sys](README.md).
