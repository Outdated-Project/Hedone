//! Same-origin Flutter Web host with isolated, expiring server-side sessions.
use crate::json_http::Json;
use crate::{
    api::Api,
    bridge::{Runtime, execute},
    gateway,
};
use axum::{
    Router,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::post,
};
use nextjson::NsonDeserialize as Deserialize;
use nextjson::{Value, json};
use rand::Rng;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tokio::sync::{Mutex, RwLock, Semaphore};
use tower_http::services::{ServeDir, ServeFile};

struct Client {
    runtime: Runtime,
    csrf: String,
    expires: Instant,
}
struct Server {
    secret: String,
    origin: String,
    secure: bool,
    gateway: gateway::Gateway,
    clients: Mutex<HashMap<String, Arc<Client>>>,
    permits: Semaphore,
}
fn random_token() -> String {
    let mut value = [0u8; 32];
    rand::rng().fill_bytes(&mut value);
    value.iter().map(|b| format!("{b:02x}")).collect()
}

pub async fn run() -> Result<(), String> {
    let secret =
        std::env::var("HEDONE_WEB_TOKEN").map_err(|_| "请设置至少 32 字节的 HEDONE_WEB_TOKEN")?;
    if secret.len() < 32 {
        return Err("HEDONE_WEB_TOKEN 至少需要 32 字节".into());
    }
    let bind = std::env::var("HEDONE_BIND").unwrap_or_else(|_| "127.0.0.1:8080".into());
    let origin =
        std::env::var("HEDONE_PUBLIC_ORIGIN").unwrap_or_else(|_| "http://127.0.0.1:8080".into());
    let url = url::Url::parse(&origin).map_err(|_| "HEDONE_PUBLIC_ORIGIN 无效")?;
    if url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || !matches!(url.scheme(), "http" | "https")
    {
        return Err("HEDONE_PUBLIC_ORIGIN 必须是完整、无路径的 HTTP(S) origin".into());
    }
    if url.scheme() != "https"
        && !matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
    {
        return Err("远程部署必须使用 HTTPS origin".into());
    }
    let dir =
        PathBuf::from(std::env::var("HEDONE_DATA_DIR").unwrap_or_else(|_| ".hedone-data".into()));
    std::fs::create_dir_all(&dir).map_err(|_| "无法创建服务数据目录")?;
    crate::net::bind_base(&dir);
    crate::dns::initialize(&dir).await?;
    crate::playback_log::bind(&dir);
    crate::network_policy::set_strict_security(true)?;
    let (gateway, media_routes) = gateway::web_routes(&url, random_token());
    let state = Arc::new(Server {
        secret,
        origin: url.origin().ascii_serialization(),
        secure: url.scheme() == "https",
        gateway,
        clients: Mutex::new(HashMap::new()),
        permits: Semaphore::new(24),
    });
    let web = PathBuf::from(std::env::var("HEDONE_WEB_DIR").unwrap_or_else(|_| "build/web".into()));
    if !web.join("index.html").is_file() {
        return Err("缺少 Flutter Web 产物，请先运行 flutter build web".into());
    }
    let app = Router::new()
        .route("/api/connect", post(connect))
        .route("/api/bootstrap", post(bootstrap))
        .route("/api/request", post(request))
        .route("/api/media", post(media_url))
        .route("/api/disconnect", post(disconnect))
        .with_state(state.clone())
        .merge(media_routes)
        .fallback_service(
            ServeDir::new(&web).not_found_service(ServeFile::new(web.join("index.html"))),
        )
        .layer(DefaultBodyLimit::max(32768))
        .layer(middleware::from_fn_with_state(state, security_headers));
    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .map_err(|e| format!("Unable to listen on {bind}: {e}"))?;
    eprintln!("Hedone Web listening on {bind}; configured origin {origin}");
    axum::serve(listener, app).await.map_err(|e| e.to_string())
}

async fn security_headers(
    State(s): State<Arc<Server>>,
    request: axum::extract::Request,
    next: Next,
) -> Response {
    if request.uri().path().starts_with("/media/")
        && let Err(response) = client(&s, request.headers(), false).await
    {
        return failure(response.0, response.1);
    }
    if request.uri().path().starts_with("/api/")
        && request
            .headers()
            .get("origin")
            .and_then(|v| v.to_str().ok())
            != Some(&s.origin)
    {
        return failure(StatusCode::FORBIDDEN, "Source mismatch");
    }
    let mut response = next.run(request).await;
    for (key, value) in [
        ("x-content-type-options", "nosniff"),
        ("referrer-policy", "no-referrer"),
        ("x-frame-options", "DENY"),
        ("cross-origin-resource-policy", "same-origin"),
        ("cache-control", "no-store"),
        (
            "content-security-policy",
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self' blob:; worker-src 'self' blob:; font-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
        ),
    ] {
        response
            .headers_mut()
            .insert(key, HeaderValue::from_static(value));
    }
    response
}
fn failure(status: StatusCode, error: &str) -> Response {
    (status, Json(json!({"error":error}))).into_response()
}
fn cookie_id(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("cookie")?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|p| p.trim().strip_prefix("hg_session="))
}
async fn client(
    s: &Server,
    h: &HeaderMap,
    csrf: bool,
) -> Result<Arc<Client>, (StatusCode, &'static str)> {
    let id = cookie_id(h).ok_or((
        StatusCode::UNAUTHORIZED,
        "Please connect to your Rust service",
    ))?;
    let mut clients = s.clients.lock().await;
    clients.retain(|_, c| c.expires > Instant::now());
    let c = clients
        .get(id)
        .cloned()
        .ok_or((StatusCode::UNAUTHORIZED, "Service session has expired"))?;
    if csrf && h.get("x-hg-csrf").and_then(|v| v.to_str().ok()) != Some(&c.csrf) {
        return Err((StatusCode::FORBIDDEN, "Request validation failed"));
    }
    Ok(c)
}
#[derive(Deserialize)]
struct Connect {
    key: String,
}
async fn connect(State(s): State<Arc<Server>>, Json(body): Json<Connect>) -> Response {
    if !bool::from(body.key.as_bytes().ct_eq(s.secret.as_bytes())) {
        return failure(StatusCode::UNAUTHORIZED, "Service access key is incorrect");
    }
    let mut clients = s.clients.lock().await;
    clients.retain(|_, c| c.expires > Instant::now());
    if clients.len() >= 128 {
        return failure(StatusCode::TOO_MANY_REQUESTS, "Service session is full");
    }
    let id = random_token();
    let csrf = random_token();
    clients.insert(
        id.clone(),
        Arc::new(Client {
            runtime: Runtime {
                api: Api::new(),
                gateway: s.gateway.clone(),
                identity: RwLock::new(()),
            },
            csrf: csrf.clone(),
            expires: Instant::now() + Duration::from_secs(12 * 3600),
        }),
    );
    let cookie = format!(
        "hg_session={id}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200{}",
        if s.secure { "; Secure" } else { "" }
    );
    ([("set-cookie", cookie)], Json(json!({"csrf":csrf}))).into_response()
}
async fn bootstrap(State(s): State<Arc<Server>>, headers: HeaderMap) -> Response {
    match client(&s, &headers, false).await {
        Ok(c) => match api_boot(&c).await {
            Ok(boot) => Json(json!({"csrf":c.csrf,"boot":boot})).into_response(),
            Err(e) => failure(StatusCode::BAD_GATEWAY, &e),
        },
        Err(r) => failure(r.0, r.1),
    }
}
async fn api_boot(c: &Client) -> Result<Value, String> {
    nextjson::from_str(&execute(&c.runtime, r#"{"op":"boot"}"#).await?)
        .map_err(|_| "Unable to parse the service status".into())
}
async fn request(
    State(s): State<Arc<Server>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Response {
    let c = match client(&s, &headers, true).await {
        Ok(c) => c,
        Err(r) => return failure(r.0, r.1),
    };
    let Ok(_permit) = s.permits.try_acquire() else {
        return failure(
            StatusCode::TOO_MANY_REQUESTS,
            "Service is busy, please try again later",
        );
    };
    if matches!(
        body["op"].as_str(),
        Some("line_set" | "log_set" | "log_read" | "log_write" | "cache_clear")
    ) {
        return failure(
            StatusCode::FORBIDDEN,
            "This setting is managed by the service administrator",
        );
    }
    match execute(&c.runtime, &body.to_string()).await {
        Ok(value) => ([("content-type", "application/json")], value).into_response(),
        Err(e) => failure(StatusCode::BAD_GATEWAY, &e),
    }
}
#[derive(Deserialize)]
struct Media {
    url: String,
    image: bool,
}
async fn media_url(
    State(s): State<Arc<Server>>,
    headers: HeaderMap,
    Json(body): Json<Media>,
) -> Response {
    if let Err(r) = client(&s, &headers, true).await {
        return failure(r.0, r.1);
    }
    if body.url.len() > 16384 || crate::network_policy::parse_target(&body.url).is_err() {
        return failure(StatusCode::BAD_REQUEST, "Invalid media address");
    }
    let route = if body.image { "img" } else { "stream" };
    Json(json!({"url":crate::media::gateway_url(&s.gateway.origin, route, &body.url)}))
        .into_response()
}
async fn disconnect(State(s): State<Arc<Server>>, headers: HeaderMap) -> Response {
    if let Err(r) = client(&s, &headers, true).await {
        return failure(r.0, r.1);
    }
    if let Some(id) = cookie_id(&headers) {
        s.clients.lock().await.remove(id);
    }
    (
        [(
            "set-cookie",
            "hg_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
        )],
        Json(json!({"ok":true})),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn sessions_are_isolated_expire_and_require_csrf() {
        let server = Server {
            secret: "s".repeat(32),
            origin: "https://example.com".into(),
            secure: true,
            gateway: gateway::Gateway {
                origin: "https://example.com/media/key".into(),
            },
            clients: Mutex::new(HashMap::new()),
            permits: Semaphore::new(1),
        };
        let a = Arc::new(Client {
            runtime: Runtime {
                api: Api::new(),
                gateway: server.gateway.clone(),
                identity: RwLock::new(()),
            },
            csrf: "a".into(),
            expires: Instant::now() + Duration::from_secs(60),
        });
        a.runtime
            .api
            .session
            .set("https://huangguoai.com", "secret".into(), json!({"id":1}));
        server.clients.lock().await.insert("a".into(), a);
        let mut h = HeaderMap::new();
        h.insert("cookie", HeaderValue::from_static("hg_session=a"));
        assert!(client(&server, &h, true).await.is_err());
        h.insert("x-hg-csrf", HeaderValue::from_static("a"));
        assert!(client(&server, &h, true).await.is_ok());
        h.insert("cookie", HeaderValue::from_static("hg_session=b"));
        assert!(client(&server, &h, true).await.is_err());
        assert!(Api::new().session.token("https://huangguoai.com").is_none());
    }
}
