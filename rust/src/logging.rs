//! UTC timestamps for opt-in diagnostics.
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

pub(crate) fn utc_timestamp() -> Result<String, String> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|_| "日志时间格式错误".to_string())
}
