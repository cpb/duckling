use chrono::{FixedOffset, Offset, TimeZone, Utc};
use chrono_tz::Tz;
use duckling::{
    Context, DimensionKind, DimensionValue, Entity, Lang, Locale, Options, Region, TimePoint,
    TimeValue, parse as duckling_parse,
};
use magnus::{Error, RArray, Ruby, Time as RubyTime, Value, function, prelude::*, scan_args};
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
    let panicking_fake = module.define_module("PanickingNativeFake")?;
    panicking_fake.define_singleton_method("parse", function!(panicking_parse, -1))?;
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
        Err(panic_payload) => Err(panic_message(&*panic_payload)),
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
        "no panic message".to_string()
    }
}

/// Converts a caught `duckling::parse` panic into the Ruby error the
/// extension raises. Single choke point for the panic → exception mapping,
/// shared by the real entrypoint and `Duckling::PanickingNativeFake`, so
/// tests exercising the fake exercise the exact mapping callers see.
///
/// Deliberately `RuntimeError` (a `StandardError`), not magnus's own
/// `Error::from_panic` convention of `fatal`: a native panic already cost
/// the caller nothing but this one call, so it must be an ordinary
/// `rescue => e`-able error, not one that also tears down the calling
/// Thread's `Thread#value`/`Thread#join` propagation as unrescuable.
fn panic_error(ruby: &Ruby, message: &str) -> Error {
    Error::new(
        ruby.exception_runtime_error(),
        format!("duckling::parse panicked: {message}"),
    )
}

/// Shorthand for the `Error::new(ruby.exception_arg_error(), ...)` pattern
/// repeated across `parse_locale`, `parse_dims`, and `build_context`.
fn arg_error(ruby: &Ruby, message: impl Into<String>) -> Error {
    Error::new(ruby.exception_arg_error(), message.into())
}

/// Payload for the test-only panicking fake below — same "plain owned Rust
/// data only" rule as `ParsePayload`.
struct PanicFakePayload {
    result: Option<Result<Vec<Entity>, String>>,
}

/// Off-GVL callback for `Duckling::PanickingNativeFake.parse`: identical
/// shape to `parse_without_gvl`, but the guarded computation always panics —
/// standing in for a `duckling::parse` panic without needing a real
/// panic-triggering input.
unsafe extern "C" fn panic_fake_without_gvl(payload: *mut c_void) -> *mut c_void {
    let payload = unsafe { &mut *(payload as *mut PanicFakePayload) };

    let outcome = catch_unwind(AssertUnwindSafe(|| -> Vec<Entity> {
        panic!("intentional panic from Duckling::PanickingNativeFake")
    }));

    payload.result = Some(match outcome {
        Ok(entities) => Ok(entities),
        Err(panic_payload) => Err(panic_message(&*panic_payload)),
    });

    std::ptr::null_mut()
}

/// `Duckling::PanickingNativeFake.parse(*)` — test-only stand-in for
/// `Duckling::Native` whose native call always panics. Accepts (and
/// ignores) `Native.parse`'s arguments so tests can swap the `Native`
/// constant and drive the public `Duckling.parse` through the real
/// GVL-release + `catch_unwind` + `panic_error` path, observing exactly
/// what a `duckling::parse` panic does to a Ruby caller. Not part of the
/// public API.
fn panicking_parse(ruby: &Ruby, _args: &[Value]) -> Result<RArray, Error> {
    let mut payload = PanicFakePayload { result: None };

    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(panic_fake_without_gvl),
            &mut payload as *mut PanicFakePayload as *mut c_void,
            None,
            std::ptr::null_mut(),
        );
    }

    match payload
        .result
        .expect("panic_fake_without_gvl always sets result before returning")
    {
        Ok(_) => Ok(ruby.ary_new()),
        Err(message) => Err(panic_error(ruby, &message)),
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
/// - `reference_time`: a Ruby `Time` anchoring relative expressions like "tomorrow";
///   its `utc_offset` is preserved into every time result's `:value` — both
///   `Instant` results (e.g. "in one hour") and `Naive` (wall-clock) results
///   (e.g. "tomorrow", "5pm"), which are resolved against this offset before
///   being returned. `:value` is always a real Ruby `Time`, never a string.
///   Defaults to `Context::default()` (now, UTC) when `nil`/omitted. A
///   non-`Time` value raises `TypeError`.
/// - `with_latent`: include ambiguous/latent matches (e.g. bare "morning").
/// - `reference_zone`: an IANA zone name (e.g. `"America/New_York"`),
///   resolved via `chrono-tz` (compiled-in IANA tzdata, no runtime file
///   I/O — a good fit alongside this gem's precompiled binary distribution).
///   When given, every `TimePoint::Naive` (wall-clock) result's offset is
///   resolved against this zone for *that result's own date* (see
///   `resolve_naive`), instead of the single fixed `reference_time`/default
///   offset. `TimePoint::Instant` results are unaffected (issue #83's known,
///   out-of-scope limitation — the wrapped duckling crate's own arithmetic,
///   e.g. `checked_add_signed` in its `dimensions/time/mod.rs`, operates on
///   `DateTime<FixedOffset>` throughout and has no zone concept to plumb
///   this through internally without an upstream change to `Context` and
///   every such call site there).
///   `reference_time` and `reference_zone` given together: raises
///   `ArgumentError` unless `reference_time`'s `utc_offset` agrees with the
///   zone's real offset at that instant. `reference_zone` given alone:
///   anchors at the current time in that zone.
fn parse(ruby: &Ruby, args: &[Value]) -> Result<RArray, Error> {
    let args = scan_args::scan_args::<(String,), (), (), (), _, ()>(args)?;
    let kw = scan_args::get_kwargs::<
        _,
        (),
        (
            Option<String>,
            Option<Vec<String>>,
            Option<RubyTime>,
            Option<bool>,
            Option<String>,
        ),
        (),
    >(
        args.keywords,
        &[],
        &[
            "locale",
            "dims",
            "reference_time",
            "with_latent",
            "reference_zone",
        ],
    )?;

    let text = args.required.0;
    let (locale_str, dims_strs, ref_time, with_latent, reference_zone_str) = kw.optional;
    let locale_str = locale_str.unwrap_or_else(|| "en".to_string());
    let dims_strs = dims_strs.unwrap_or_else(|| vec!["time".to_string()]);
    let with_latent = with_latent.unwrap_or(false);

    let locale = parse_locale(ruby, &locale_str)?;
    let dims = parse_dims(ruby, &dims_strs)?;
    let zone = match &reference_zone_str {
        Some(name) => Some(
            name.parse::<Tz>()
                .map_err(|_| arg_error(ruby, format!("invalid reference_zone: {name:?}")))?,
        ),
        None => None,
    };
    let context = build_context(ruby, ref_time, zone)?;
    let options = Options { with_latent };

    // Release the GVL, call duckling::parse off-GVL, and block until the
    // GVL is reacquired (rb_thread_call_without_gvl's documented step 4)
    // before touching any Ruby Value again. The payload lives on this stack
    // frame: rb_thread_call_without_gvl runs the callback to completion
    // before returning, so no heap allocation or ownership transfer is
    // needed — the borrow ends when the call returns.
    let mut payload = ParsePayload {
        text,
        locale,
        dims,
        context,
        options,
        result: None,
    };

    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(parse_without_gvl),
            &mut payload as *mut ParsePayload as *mut c_void,
            None, // ubf: no cancellation hook (Thread#raise/#kill against an
            // in-flight parse isn't handled — see issue #64's "Out of scope")
            std::ptr::null_mut(),
        );
    }

    let offset = payload.context.timezone();
    let entities = match payload
        .result
        .expect("parse_without_gvl always sets result before returning")
    {
        Ok(entities) => entities,
        // Safe to construct/raise now: the GVL is confirmed held again.
        Err(message) => return Err(panic_error(ruby, &message)),
    };

    let out = ruby.ary_new();
    for e in &entities {
        out.push(entity_to_ruby(ruby, e, offset, zone)?)?;
    }
    Ok(out)
}

fn parse_locale(ruby: &Ruby, locale_str: &str) -> Result<Locale, Error> {
    let mut parts = locale_str.splitn(2, '-');
    let lang_code = parts.next().unwrap_or("");
    let region_code = parts.next();

    let lang = lang_from_code(lang_code)
        .ok_or_else(|| arg_error(ruby, format!("unsupported locale: {locale_str:?}")))?;

    let region = match region_code {
        Some(code) => Some(
            region_from_code(code)
                .ok_or_else(|| arg_error(ruby, format!("unsupported locale: {locale_str:?}")))?,
        ),
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
            other => Err(arg_error(ruby, format!("unsupported dimension: {other:?}"))),
        })
        .collect()
}

/// Builds the wrapped crate's `Context`, applying `reference_zone:`
/// validation/anchoring around the plain `reference_time:` anchor
/// computation (unchanged from before `reference_zone:` existed):
/// - both given: raises `ArgumentError` unless `reference_time`'s offset
///   agrees with `zone`'s real offset at that exact instant.
/// - `zone` alone: anchors at the current time in that zone (the
///   `reference_time: Time.now` equivalent the issue's acceptance criteria
///   describes), instead of `Context::default()`'s UTC now.
/// - `reference_time` alone, or neither: exactly as before.
fn build_context(
    ruby: &Ruby,
    ref_time: Option<RubyTime>,
    zone: Option<Tz>,
) -> Result<Context, Error> {
    let anchor = match ref_time {
        Some(time) => {
            let ts = time.timespec()?;
            let offset = FixedOffset::east_opt(time.utc_offset() as i32).ok_or_else(|| {
                arg_error(ruby, "invalid reference_time: utc_offset out of range")
            })?;
            Some(
                offset
                    .timestamp_opt(ts.tv_sec, ts.tv_nsec as u32)
                    .single()
                    .ok_or_else(|| {
                        arg_error(ruby, "invalid reference_time: timestamp out of range")
                    })?,
            )
        }
        None => None,
    };

    match (anchor, zone) {
        (Some(anchor), Some(tz)) => {
            let zone_offset = tz.offset_from_utc_datetime(&anchor.naive_utc()).fix();
            if zone_offset.local_minus_utc() != anchor.offset().local_minus_utc() {
                return Err(arg_error(
                    ruby,
                    format!(
                        "reference_time's utc_offset ({}) does not match reference_zone's \
                         utc_offset ({}) at that instant",
                        anchor.offset().local_minus_utc(),
                        zone_offset.local_minus_utc(),
                    ),
                ));
            }
            Ok(Context::new(anchor, Locale::default()))
        }
        (Some(anchor), None) => Ok(Context::new(anchor, Locale::default())),
        (None, Some(tz)) => Ok(Context::new(
            Utc::now().with_timezone(&tz).fixed_offset(),
            Locale::default(),
        )),
        (None, None) => Ok(Context::default()),
    }
}

/// Resolves a bare `NaiveDateTime` (wall-clock, no offset) into an absolute
/// `DateTime<FixedOffset>`. Shared by `time_point_to_ruby` and
/// `time_value_to_ruby` so the two call sites can't drift apart on error
/// message or ambiguity-handling strategy.
///
/// This is the seam `reference_zone:` support hooks into: when `zone` is
/// `Some`, it resolves this value's own wall-clock components against the
/// real IANA zone for *that date* via `chrono-tz` instead of the single
/// fixed `offset` — no separate tag needs to cross into Ruby for it to know
/// which results are eligible, since this call site already has the
/// Naive/Instant distinction in hand (only the `TimePoint::Naive` match arms
/// call this function at all). `DateTime<Tz>::fixed_offset()` converts back
/// to the same `DateTime<FixedOffset>` shape the `None` branch already
/// returns, so callers need no changes either way.
///
/// `FixedOffset` (and, per-date, `Tz`) has no ambiguity in the cases
/// duckling can produce in practice, so `.single()` is total; the
/// `ok_or_else` is defensive.
fn resolve_naive(
    ruby: &Ruby,
    offset: FixedOffset,
    zone: Option<Tz>,
    value: &chrono::NaiveDateTime,
) -> Result<chrono::DateTime<FixedOffset>, Error> {
    if let Some(zone) = zone {
        return zone
            .from_local_datetime(value)
            .single()
            .map(|dt| dt.fixed_offset())
            .ok_or_else(|| arg_error(ruby, "invalid or ambiguous naive time for reference zone"));
    }

    offset
        .from_local_datetime(value)
        .single()
        .ok_or_else(|| arg_error(ruby, "invalid or ambiguous naive time for reference offset"))
}

fn time_point_to_ruby(
    ruby: &Ruby,
    tp: &TimePoint,
    offset: FixedOffset,
    zone: Option<Tz>,
) -> Result<Value, Error> {
    let h = ruby.hash_new();
    h.aset(ruby.to_symbol("type"), ruby.to_symbol("value"))?;
    match tp {
        TimePoint::Naive { value, grain } => {
            h.aset(
                ruby.to_symbol("value"),
                resolve_naive(ruby, offset, zone, value)?,
            )?;
            h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
        }
        TimePoint::Instant { value, grain } => {
            h.aset(ruby.to_symbol("value"), *value)?;
            h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
        }
    }
    Ok(h.as_value())
}

fn time_value_to_ruby(
    ruby: &Ruby,
    tv: &TimeValue,
    offset: FixedOffset,
    zone: Option<Tz>,
) -> Result<Value, Error> {
    let h = ruby.hash_new();
    match tv {
        TimeValue::Single { value, values, .. } => {
            h.aset(ruby.to_symbol("type"), ruby.to_symbol("value"))?;
            match value {
                TimePoint::Naive { value: dt, grain } => {
                    h.aset(
                        ruby.to_symbol("value"),
                        resolve_naive(ruby, offset, zone, dt)?,
                    )?;
                    h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
                }
                TimePoint::Instant { value: dt, grain } => {
                    h.aset(ruby.to_symbol("value"), *dt)?;
                    h.aset(ruby.to_symbol("grain"), ruby.to_symbol(grain.as_str()))?;
                }
            }
            let vals = ruby.ary_new();
            for tp in values {
                vals.push(time_point_to_ruby(ruby, tp, offset, zone)?)?;
            }
            h.aset(ruby.to_symbol("values"), vals)?;
        }
        TimeValue::Interval { from, to, .. } => {
            h.aset(ruby.to_symbol("type"), ruby.to_symbol("interval"))?;
            if let Some(tp) = from {
                h.aset(
                    ruby.to_symbol("from"),
                    time_point_to_ruby(ruby, tp, offset, zone)?,
                )?;
            }
            if let Some(tp) = to {
                h.aset(
                    ruby.to_symbol("to"),
                    time_point_to_ruby(ruby, tp, offset, zone)?,
                )?;
            }
        }
    }
    Ok(h.as_value())
}

fn entity_to_ruby(
    ruby: &Ruby,
    entity: &Entity,
    offset: FixedOffset,
    zone: Option<Tz>,
) -> Result<Value, Error> {
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
        h.aset(
            ruby.to_symbol("value"),
            time_value_to_ruby(ruby, tv, offset, zone)?,
        )?;
    }
    Ok(h.as_value())
}
