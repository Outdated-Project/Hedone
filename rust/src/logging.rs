//! UTC timestamps for opt-in diagnostics.
use std::time::{SystemTime, UNIX_EPOCH};
use tzcraft::{FractionDigits, Ticks};

pub(crate) fn utc_timestamp() -> Result<String, String> {
    let now = SystemTime::now();
    let nanos = match now.duration_since(UNIX_EPOCH) {
        Ok(span) => span.as_nanos() as i128,
        Err(error) => -(error.duration().as_nanos() as i128),
    };
    Ok(Ticks::from_timestamp_nanos(nanos).to_rfc3339(FractionDigits::Auto))
}
