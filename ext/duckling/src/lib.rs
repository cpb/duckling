use chrono::DateTime;
use duckling::{
    parse as duckling_parse, Context, DimensionKind, DimensionValue, Entity, Lang, Locale, Options,
    Region, TimePoint, TimeValue,
};
use magnus::{function, prelude::*, scan_args, Error, RArray, Ruby, Value};

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Duckling")?;
    module.define_singleton_method("parse", function!(parse, -1))?;
    Ok(())
}

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

    let entities = duckling_parse(&text, &locale, &dims, &context, &options);

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
