use chrono::DateTime;
use duckling::{
    Context, DimensionKind, DimensionValue, Entity, Lang, Locale, Options, Region, TimePoint,
    TimeValue, parse as duckling_parse,
};
use magnus::{Error, RArray, Ruby, Value, function, prelude::*, scan_args};
use std::os::raw::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};

// `Duckling::Native` holds the raw Magnus-defined entrypoint; `Duckling.parse`
// itself is a thin Ruby-level wrapper (see lib/duckling.rb) that dispatches
// through a `Thread.new { ... }.value` so a calling Fiber on an Async::Reactor
// can yield to sibling Fibers while the GVL-released native call runs (issue
// #64). Keeping the native singleton method under a separate `Native` module
// — rather than directly on `Duckling` — is what makes that split possible:
// it gives Ruby code something to call *without* the thread-spawn, which the
// benchmark suite also relies on to measure the dispatch overhead directly.
#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Duckling")?;
    let native = module.define_module("Native")?;
    native.define_singleton_method("parse", function!(parse, -1))?;
    Ok(())
}

/// Everything the off-GVL callback needs, and everything it produces.
/// Deliberately holds only fully-owned Rust data — no `magnus::Value`, no
/// `magnus::Error`, no other Ruby-VM-touching type crosses this struct in
/// either direction (this repo's established rule: never stash a bare
/// `magnus::Value`, or anything wrapping one, across a Magnus call boundary —
/// a past incident here caused a real GC-safety segfault).
struct ParsePayload {
    text: String,
    locale: Locale,
    dims: Vec<DimensionKind>,
    context: Context,
    options: Options,
    result: Option<Result<Vec<Entity>, String>>,
}

/// The raw callback handed to `rb_thread_call_without_gvl` as `func`. Runs
/// with the GVL released: no Ruby method calls, no `Value`/`RArray`
/// construction, no `magnus::Error` construction or raising is permitted
/// here — only the plain Rust computation and writing plain Rust data back
/// into `*payload`. Wraps the call in `std::panic::catch_unwind` directly
/// (not `magnus::rb_sys::catch_unwind`) to keep the payload's "plain Rust
/// data only" invariant simple and mechanically checkable.
///
/// This guard is required unconditionally, not just as release-profile
/// defense-in-depth: the wrapped `duckling` crate's own internal
/// `catch_unwind` is compiled out entirely under `#[cfg(not(debug_assertions))]`,
/// which is absent from this repo's own `dev`-profile local default
/// (`RB_SYS_CARGO_PROFILE=dev`, set via `.env.local`).
unsafe extern "C" fn parse_without_gvl(payload: *mut c_void) -> *mut c_void {
    // Edition 2024 requires unsafe operations to be wrapped in their own
    // `unsafe` block even inside an `unsafe fn` (unsafe_op_in_unsafe_fn).
    let payload = unsafe { &mut *(payload as *mut ParsePayload) };

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

    // Return value is unused by our caller (the real result is read back out
    // of `*payload`); the C API just requires we return *something*.
    std::ptr::null_mut()
}

/// Mirrors duckling's own panic_payload_message downcast (`&str` / `String` /
/// fallback), kept local since we don't have access to duckling's private helper.
fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(&s) = payload.downcast_ref::<&'static str>() {
        s.to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "duckling::parse panicked".to_string()
    }
}

/// `Duckling::Native.parse(text, locale: "en", dims: ["time"], reference_time: nil, with_latent: false)`
///
/// The raw native entrypoint — no Thread spawn, no GVL-release considerations
/// visible at the call site. `Duckling.parse` (see lib/duckling.rb) is the
/// public API; it wraps this in `Thread.new { ... }.value` for thread-per-call
/// dispatch. Called directly (no thread), this is also the "without" baseline
/// the benchmark suite compares thread-per-call dispatch overhead against.
///
/// - `locale`: BCP-47 tag (e.g. `"en"`, `"en-GB"`); unsupported codes raise `ArgumentError`.
/// - `dims`: dimension names to extract; only `"time"` is implemented in 0.2.0,
///   other values raise `ArgumentError`.
/// - `reference_time`: Unix seconds anchoring relative expressions like "tomorrow";
///   defaults to `Context::default()` (now, UTC).
/// - `with_latent`: include ambiguous/latent matches (e.g. bare "morning").
fn parse(ruby: &Ruby, args: &[Value]) -> Result<RArray, Error> {
    let args = scan_args::scan_args::<(String,), (), (), (), _, ()>(args)?;
    let kw = scan_args::get_kwargs::<
        _,
        (),
        (
            Option<String>,
            Option<Vec<String>>,
            Option<i64>,
            Option<bool>,
        ),
        (),
    >(
        args.keywords,
        &[],
        &["locale", "dims", "reference_time", "with_latent"],
    )?;

    let text = args.required.0;
    let (locale_str, dims_strs, ref_time_i, with_latent) = kw.optional;
    let locale_str = locale_str.unwrap_or_else(|| "en".to_string());
    let dims_strs = dims_strs.unwrap_or_else(|| vec!["time".to_string()]);
    let with_latent = with_latent.unwrap_or(false);

    let locale = parse_locale(ruby, &locale_str)?;
    let dims = parse_dims(ruby, &dims_strs)?;
    let context = build_context(ruby, ref_time_i)?;
    let options = Options { with_latent };

    // Box the owned inputs, release the GVL, call duckling::parse off-GVL,
    // and block until the GVL is reacquired (rb_thread_call_without_gvl's
    // documented step 4) before touching any Ruby Value again.
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
            None, // ubf: no cancellation hook (Thread#raise/#kill against an
            // in-flight parse isn't handled — see issue #64's "Out of scope")
            std::ptr::null_mut(),
        );
    }

    // Reclaim ownership now that the GVL is confirmed held again. This is the
    // only place the payload is freed — the callback above never frees it.
    let boxed = unsafe { Box::from_raw(payload_ptr as *mut ParsePayload) };
    let entities = match boxed
        .result
        .expect("parse_without_gvl always sets result before returning")
    {
        Ok(entities) => entities,
        Err(message) => {
            // Safe to construct/raise now: the GVL is confirmed held again.
            return Err(Error::new(
                ruby.exception_fatal(),
                format!("duckling::parse panicked: {message}"),
            ));
        }
    };

    let out = ruby.ary_new();
    for e in &entities {
        out.push(entity_to_ruby(ruby, e)?)?;
    }
    Ok(out)
}

fn parse_locale(ruby: &Ruby, locale_str: &str) -> Result<Locale, Error> {
    let mut parts = locale_str.splitn(2, '-');
    let lang_code = parts.next().unwrap_or("");
    let region_code = parts.next();

    let lang = lang_from_code(lang_code).ok_or_else(|| {
        Error::new(
            ruby.exception_arg_error(),
            format!("unsupported locale: {locale_str:?}"),
        )
    })?;

    let region = match region_code {
        Some(code) => Some(region_from_code(code).ok_or_else(|| {
            Error::new(
                ruby.exception_arg_error(),
                format!("unsupported locale: {locale_str:?}"),
            )
        })?),
        None => None,
    };

    Ok(Locale::new(lang, region))
}

fn lang_from_code(code: &str) -> Option<Lang> {
    Some(match code.to_ascii_lowercase().as_str() {
        "af" => Lang::AF,
        "ar" => Lang::AR,
        "bg" => Lang::BG,
        "bn" => Lang::BN,
        "ca" => Lang::CA,
        "cs" => Lang::CS,
        "da" => Lang::DA,
        "de" => Lang::DE,
        "el" => Lang::EL,
        "en" => Lang::EN,
        "es" => Lang::ES,
        "et" => Lang::ET,
        "fa" => Lang::FA,
        "fi" => Lang::FI,
        "fr" => Lang::FR,
        "ga" => Lang::GA,
        "he" => Lang::HE,
        "hi" => Lang::HI,
        "hr" => Lang::HR,
        "hu" => Lang::HU,
        "id" => Lang::ID,
        "is" => Lang::IS,
        "it" => Lang::IT,
        "ja" => Lang::JA,
        "ka" => Lang::KA,
        "km" => Lang::KM,
        "kn" => Lang::KN,
        "ko" => Lang::KO,
        "lo" => Lang::LO,
        "ml" => Lang::ML,
        "mn" => Lang::MN,
        "my" => Lang::MY,
        "nb" => Lang::NB,
        "ne" => Lang::NE,
        "nl" => Lang::NL,
        "pl" => Lang::PL,
        "pt" => Lang::PT,
        "ro" => Lang::RO,
        "ru" => Lang::RU,
        "sk" => Lang::SK,
        "sv" => Lang::SV,
        "sw" => Lang::SW,
        "ta" => Lang::TA,
        "te" => Lang::TE,
        "th" => Lang::TH,
        "tr" => Lang::TR,
        "uk" => Lang::UK,
        "vi" => Lang::VI,
        "zh" => Lang::ZH,
        _ => return None,
    })
}

fn region_from_code(code: &str) -> Option<Region> {
    Some(match code.to_ascii_uppercase().as_str() {
        "AR" => Region::AR,
        "US" => Region::US,
        "GB" => Region::GB,
        "AU" => Region::AU,
        "BE" => Region::BE,
        "BZ" => Region::BZ,
        "CA" => Region::CA,
        "CL" => Region::CL,
        "CN" => Region::CN,
        "CO" => Region::CO,
        "EG" => Region::EG,
        "ES" => Region::ES,
        "HK" => Region::HK,
        "IE" => Region::IE,
        "IN" => Region::IN,
        "JM" => Region::JM,
        "MO" => Region::MO,
        "MX" => Region::MX,
        "NZ" => Region::NZ,
        "PE" => Region::PE,
        "PH" => Region::PH,
        "TT" => Region::TT,
        "TW" => Region::TW,
        "VE" => Region::VE,
        "ZA" => Region::ZA,
        _ => return None,
    })
}

fn parse_dims(ruby: &Ruby, dims_strs: &[String]) -> Result<Vec<DimensionKind>, Error> {
    dims_strs
        .iter()
        .map(|s| match s.as_str() {
            "time" => Ok(DimensionKind::Time),
            "number" => Ok(DimensionKind::Numeral),
            "ordinal" => Ok(DimensionKind::Ordinal),
            "temperature" => Ok(DimensionKind::Temperature),
            "distance" => Ok(DimensionKind::Distance),
            "volume" => Ok(DimensionKind::Volume),
            "quantity" => Ok(DimensionKind::Quantity),
            "amount-of-money" => Ok(DimensionKind::AmountOfMoney),
            "email" => Ok(DimensionKind::Email),
            "phone-number" => Ok(DimensionKind::PhoneNumber),
            "url" => Ok(DimensionKind::Url),
            "credit-card-number" => Ok(DimensionKind::CreditCardNumber),
            "time-grain" => Ok(DimensionKind::TimeGrain),
            "duration" => Ok(DimensionKind::Duration),
            other => Err(Error::new(
                ruby.exception_arg_error(),
                format!("unsupported dimension: {other:?}"),
            )),
        })
        .collect()
}

fn build_context(ruby: &Ruby, ref_time_i: Option<i64>) -> Result<Context, Error> {
    match ref_time_i {
        Some(secs) => {
            let utc = DateTime::from_timestamp(secs, 0)
                .ok_or_else(|| Error::new(ruby.exception_arg_error(), "invalid reference_time"))?;
            Ok(Context::new(utc.fixed_offset(), Locale::default()))
        }
        None => Ok(Context::default()),
    }
}

fn time_point_to_ruby(ruby: &Ruby, tp: &TimePoint) -> Result<Value, Error> {
    let h = ruby.hash_new();
    h.aset(ruby.to_symbol("type"), ruby.to_symbol("value"))?;
    match tp {
        TimePoint::Naive { value, grain } => {
            h.aset(
                ruby.to_symbol("value"),
                value.format("%Y-%m-%dT%H:%M:%S").to_string(),
            )?;
            h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
        }
        TimePoint::Instant { value, grain } => {
            h.aset(ruby.to_symbol("value"), value.to_rfc3339())?;
            h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
        }
    }
    Ok(h.as_value())
}

fn time_value_to_ruby(ruby: &Ruby, tv: &TimeValue) -> Result<Value, Error> {
    let h = ruby.hash_new();
    match tv {
        TimeValue::Single { value, values, .. } => {
            h.aset(ruby.to_symbol("type"), ruby.to_symbol("value"))?;
            match value {
                TimePoint::Naive { value: dt, grain } => {
                    h.aset(
                        ruby.to_symbol("value"),
                        dt.format("%Y-%m-%dT%H:%M:%S").to_string(),
                    )?;
                    h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
                }
                TimePoint::Instant { value: dt, grain } => {
                    h.aset(ruby.to_symbol("value"), dt.to_rfc3339())?;
                    h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
                }
            }
            let vals = ruby.ary_new();
            for tp in values {
                vals.push(time_point_to_ruby(ruby, tp)?)?;
            }
            h.aset(ruby.to_symbol("values"), vals)?;
        }
        TimeValue::Interval { from, to, .. } => {
            h.aset(ruby.to_symbol("type"), ruby.to_symbol("interval"))?;
            if let Some(tp) = from {
                h.aset(ruby.to_symbol("from"), time_point_to_ruby(ruby, tp)?)?;
            }
            if let Some(tp) = to {
                h.aset(ruby.to_symbol("to"), time_point_to_ruby(ruby, tp)?)?;
            }
        }
    }
    Ok(h.as_value())
}

fn entity_to_ruby(ruby: &Ruby, entity: &Entity) -> Result<Value, Error> {
    let h = ruby.hash_new();
    h.aset(ruby.to_symbol("body"), entity.body.clone())?;
    h.aset(ruby.to_symbol("start"), entity.start)?;
    h.aset(ruby.to_symbol("end"), entity.end)?;
    let dim_str = entity.value.dim_kind().to_string();
    h.aset(ruby.to_symbol("dim"), ruby.to_symbol(dim_str.as_str()))?;
    if let Some(latent) = entity.latent {
        h.aset(ruby.to_symbol("latent"), latent)?;
    }
    if let DimensionValue::Time(ref tv) = entity.value {
        h.aset(ruby.to_symbol("value"), time_value_to_ruby(ruby, tv)?)?;
    }
    Ok(h.as_value())
}
