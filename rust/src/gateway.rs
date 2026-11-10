//! Native decoders share this process-local, capability-protected media transport.
//! No business API, session or arbitrary file access is exposed over HTTP.
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use futures_util::StreamExt;
use rand::RngCore;
use serde::Deserialize;
use std::{sync::Arc, time::Duration};
use tokio::sync::Semaphore;

#[derive(Clone)]
pub struct Gateway {
    pub origin: String,
}
struct Context {
    token: String,
    host: String,
    origin: String,
    browser_origin: Option<String>,
    permits: Arc<Semaphore>,
}

pub async fn start() -> Result<Gateway, String> {
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|_| "Unable to start the local media service")?;
    let host = listener
        .local_addr()
        .map_err(|_| "Unable to get the media port")?
        .to_string();
    let mut random = [0u8; 32];
    rand::rng().fill_bytes(&mut random);
    let token: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let origin = format!("http://{host}/{token}");
    let state = Arc::new(Context {
        token,
        host,
        origin: origin.clone(),
        browser_origin: None,
        permits: Arc::new(Semaphore::new(12)),
    });
    let router = Router::new()
        .route("/{token}/{kind}", get(serve))
        .with_state(state);
    tokio::spawn(async move {
        if axum::serve(listener, router).await.is_err() {
            crate::playback_log::record("gateway.stopped", serde_json::json!({}));
        }
    });
    Ok(Gateway { origin })
}

#[cfg(feature = "server")]
pub(crate) fn web_routes(public_origin: &url::Url, token: String) -> (Gateway, Router) {
    let host = public_origin[url::Position::BeforeHost..url::Position::AfterPort].to_string();
    let public = public_origin.origin().ascii_serialization();
    let origin = format!("{public}/media/{token}");
    let state = Arc::new(Context {
        token,
        host,
        origin: origin.clone(),
        browser_origin: Some(public),
        permits: Arc::new(Semaphore::new(12)),
    });
    (
        Gateway { origin },
        Router::new()
            .route("/media/{token}/{kind}", get(serve))
            .with_state(state),
    )
}

#[derive(Deserialize)]
struct Target {
    u: String,
}

async fn serve(
    State(ctx): State<Arc<Context>>,
    Path((token, kind)): Path<(String, String)>,
    Query(target): Query<Target>,
    headers: HeaderMap,
) -> Response {
    let origin = headers.get("origin").and_then(|h| h.to_str().ok());
    if token != ctx.token
        || headers.get("host").and_then(|h| h.to_str().ok()) != Some(ctx.host.as_str())
        || origin.is_some_and(|o| Some(o) != ctx.browser_origin.as_deref())
    {
        return StatusCode::FORBIDDEN.into_response();
    }
    if target.u.len() > 16384 {
        return StatusCode::URI_TOO_LONG.into_response();
    }
    let Ok(permit) = ctx.permits.clone().try_acquire_owned() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let mut permit = Some(permit);
    let response = if kind == "stream" {
        stream(&ctx, &target.u, &headers, permit.take().unwrap()).await
    } else if ["img", "hls", "seg"].contains(&kind.as_str()) {
        let query = format!(
            "u={}",
            percent_encoding::utf8_percent_encode(&target.u, percent_encoding::NON_ALPHANUMERIC)
        );
        let response = crate::media::handle(&format!("/{kind}"), &query, &ctx.origin).await;
        Ok(
            apply_range(response, headers.get("range").and_then(|h| h.to_str().ok()))
                .map(Body::from)
                .into_response(),
        )
    } else {
        Ok(StatusCode::NOT_FOUND.into_response())
    };
    drop(permit);
    match response {
        Ok(mut response) => {
            response
                .headers_mut()
                .insert("cache-control", http::HeaderValue::from_static("no-store"));
            response.headers_mut().insert(
                "x-content-type-options",
                http::HeaderValue::from_static("nosniff"),
            );
            response
        }
        Err(error) => {
            crate::playback_log::record(
                "gateway.failed",
                serde_json::json!({"error_kind":crate::playback_log::error_kind(&error)}),
            );
            (
                StatusCode::BAD_GATEWAY,
                "Unable to process the media request",
            )
                .into_response()
        }
    }
}

async fn stream(
    ctx: &Context,
    url: &str,
    headers: &HeaderMap,
    permit: tokio::sync::OwnedSemaphorePermit,
) -> Result<Response, String> {
    let range = headers.get("range").and_then(|h| h.to_str().ok());
    if range.is_some_and(|r| r.len() > 100 || !r.starts_with("bytes=") || r.contains(',')) {
        return Ok(StatusCode::RANGE_NOT_SATISFIABLE.into_response());
    }
    let referer = format!("{}/", crate::net::base());
    let upstream =
        crate::net::get_with_range(url, Duration::from_secs(7200), None, Some(&referer), range)
            .await?;
    let status = upstream.status();
    if !status.is_success() {
        return Ok(status.into_response());
    }
    let ctype = upstream
        .headers()
        .get("content-type")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();
    let final_url = upstream.url().to_string();
    let is_hls = ctype.to_ascii_lowercase().contains("mpegurl")
        || upstream
            .url()
            .path()
            .to_ascii_lowercase()
            .ends_with(".m3u8");
    if is_hls {
        let bytes = crate::net::read_limited(upstream, 2 * 1024 * 1024).await?;
        let text = std::str::from_utf8(&bytes).map_err(|_| "The playlist is not UTF-8")?;
        if !text.trim_start_matches('\u{feff}').starts_with("#EXTM3U") {
            return Err("Invalid playlist".into());
        }
        return Ok((
            [("content-type", "application/vnd.apple.mpegurl")],
            crate::media::rewrite_playlist(&final_url, text, &ctx.origin),
        )
            .into_response());
    }
    let mut builder = Response::builder()
        .status(status)
        .header("content-type", ctype);
    for name in ["content-length", "content-range", "accept-ranges"] {
        if let Some(value) = upstream.headers().get(name) {
            builder = builder.header(name, value);
        }
    }
    builder
        .body(Body::from_stream(upstream.bytes_stream().map(
            move |chunk| {
                let _keep_alive = &permit;
                chunk
            },
        )))
        .map_err(|_| "Unable to construct the media response".into())
}

fn apply_range(
    mut response: http::Response<axum::body::Bytes>,
    range: Option<&str>,
) -> http::Response<axum::body::Bytes> {
    let Some(range) = range else {
        return response;
    };
    if response.status() != StatusCode::OK {
        return response;
    }
    let len = response.body().len();
    let parsed = (|| {
        let (start, end) = range.strip_prefix("bytes=")?.split_once('-')?;
        if len == 0 {
            return None;
        }
        if start.is_empty() {
            let suffix = end.parse::<usize>().ok()?;
            return (suffix > 0).then_some((len.saturating_sub(suffix), len - 1));
        }
        let start = start.parse::<usize>().ok()?;
        let end = if end.is_empty() {
            len - 1
        } else {
            end.parse::<usize>().ok()?.min(len - 1)
        };
        (start <= end && start < len).then_some((start, end))
    })();
    match parsed {
        Some((start, end)) => {
            *response.body_mut() = response.body().slice(start..=end);
            *response.status_mut() = StatusCode::PARTIAL_CONTENT;
            response.headers_mut().insert(
                "content-range",
                format!("bytes {start}-{end}/{len}").parse().unwrap(),
            );
            response.headers_mut().insert(
                "content-length",
                (end - start + 1).to_string().parse().unwrap(),
            );
        }
        None => {
            *response.status_mut() = StatusCode::RANGE_NOT_SATISFIABLE;
            response.body_mut().clear();
            response
                .headers_mut()
                .insert("content-range", format!("bytes */{len}").parse().unwrap());
            response
                .headers_mut()
                .insert("content-length", http::HeaderValue::from_static("0"));
        }
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranges_share_the_original_allocation() {
        let bytes = axum::body::Bytes::from(vec![1, 2, 3, 4, 5]);
        let address = bytes.as_ptr();
        let response = apply_range(http::Response::new(bytes), Some("bytes=2-3"));
        assert_eq!(response.body().as_ptr(), address.wrapping_add(2));
        assert_eq!(response.body().as_ref(), &[3, 4]);
    }
    #[test]
    fn byte_ranges_support_seek_suffix_and_reject_invalid_requests() {
        for (range, status, body) in [
            ("bytes=2-4", 206, vec![2, 3, 4]),
            ("bytes=-2", 206, vec![8, 9]),
            ("bytes=8-", 206, vec![8, 9]),
            ("bytes=20-", 416, vec![]),
            ("bytes=4-2", 416, vec![]),
            ("bytes=0-1,3-4", 416, vec![]),
        ] {
            let r = apply_range(
                http::Response::new(axum::body::Bytes::from((0..10).collect::<Vec<u8>>())),
                Some(range),
            );
            assert_eq!(r.status().as_u16(), status);
            assert_eq!(r.body().as_ref(), body.as_slice());
        }
    }
    #[tokio::test]
    async fn gateway_rejects_wrong_capability_and_browser_origin() {
        let server = start().await.unwrap();
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let url = format!("{}/img?u=https%3A%2F%2Fexample.com", server.origin);
        assert_eq!(
            client
                .get(&url)
                .header("Origin", "https://example.com")
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        let url = url.replace(server.origin.rsplit('/').next().unwrap(), "invalid");
        assert_eq!(client.get(url).send().await.unwrap().status(), 403);
    }
}
