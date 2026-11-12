//! Validated upstream transport: DNS pinning, redirect policy and bounded reads.
use crate::network_policy;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use nextjson::{Value, json};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

/// 默认上游（固定线路 1）。
pub const DEFAULT_BASE: &str = "https://huangguoai.com";

/// 当前上游基址（不带结尾斜杠）。可在设置里切到固定线路 2 或镜像线路，运行时立即生效。
static BASE: Lazy<RwLock<String>> = Lazy::new(|| RwLock::new(DEFAULT_BASE.to_string()));
/// 线路配置落盘位置（应用数据目录/line.json），由 [`bind_base`] 在启动时绑定。
static BASE_FILE: Lazy<RwLock<Option<PathBuf>>> = Lazy::new(|| RwLock::new(None));

/// 当前上游基址。
pub fn base() -> String {
    BASE.read()
        .map(|b| b.clone())
        .unwrap_or_else(|_| DEFAULT_BASE.to_string())
}

/// 线路必须是纯 HTTPS origin，不允许路径、认证、查询串或片段。
pub fn normalize_base(raw: &str) -> Option<String> {
    let parsed = network_policy::parse_target(raw.trim()).ok()?;
    if parsed.scheme() != "https"
        || parsed.path() != "/"
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    Some(parsed.origin().ascii_serialization())
}

/// 远端发布页只提供游客镜像，不能扩展账号密码的信任范围。
pub fn trusted_auth_origin(origin: &str) -> bool {
    matches!(origin, "https://huangguoai.com" | "https://huangguoai.ai")
}

/// 启动时读回上次选择的线路（文件不存在 / 内容坏了就保持默认）。
pub fn bind_base(dir: &std::path::Path) {
    network_policy::bind_security(dir);
    let path = dir.join("line.json");
    if let Ok(text) = std::fs::read_to_string(&path)
        && let Ok(v) = nextjson::from_str::<Value>(&text)
        && let Some(next) = v
            .get("base")
            .and_then(|x| x.as_str())
            .and_then(normalize_base)
        && let Ok(mut cur) = BASE.write()
    {
        *cur = next;
    }
    if let Ok(mut f) = BASE_FILE.write() {
        *f = Some(path);
    }
}

/// 切换线路并落盘，返回规整后的地址。
pub fn set_base(url: &str) -> Result<String, String> {
    let next = normalize_base(url)
        .ok_or_else(|| "线路地址无效（需要纯 HTTPS 站点地址，禁止内网）".to_string())?;
    let previous = base();
    let file = BASE_FILE.read().map_err(|_| "线路配置锁失败")?;
    let path = file.as_ref().ok_or("线路配置尚未初始化")?;
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, json!({ "base": next }).to_string())
        .and_then(|_| std::fs::rename(&tmp, path))
        .map_err(|_| "无法保存线路配置")?;
    *BASE.write().map_err(|_| "线路配置锁失败")? = next.clone();
    if previous != next {
        crate::playback_log::record(
            "line.changed",
            json!({
                "previous_host": url::Url::parse(&previous).ok().and_then(|u| u.host_str().map(str::to_owned)),
                "line_host": url::Url::parse(&next).ok().and_then(|u| u.host_str().map(str::to_owned)),
            }),
        );
    }
    Ok(next)
}

pub const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// Construct a fresh transport after DNS validation; proxy policy is isolated.
fn build_client(
    target: &url::Url,
    addrs: &[SocketAddr],
) -> Result<crate::transport::Client, String> {
    crate::transport::Client::create(target, addrs, crate::proxy::for_url(target)?)
}

const CLIENT_TTL: Duration = Duration::from_secs(30);
type ClientCache = HashMap<String, (Instant, Arc<crate::transport::Client>)>;
static CLIENTS: Lazy<Mutex<ClientCache>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn cached_client(
    cache: &ClientCache,
    key: &str,
    now: Instant,
) -> Option<Arc<crate::transport::Client>> {
    cache
        .get(key)
        .filter(|(expires, _)| now < *expires)
        .map(|(_, http)| http.clone())
}

/// 缓存按模式、主机和端口隔离；有效期内仅复用已经检查并固定地址的客户端。
/// 到期后重新检查全部 DNS 答案，不使用旧连接绕过新的目标检查。
async fn client_for(raw: &str) -> Result<(url::Url, Arc<crate::transport::Client>), String> {
    let strict = network_policy::strict_security();
    let target = network_policy::parse_target_with_mode(raw, strict)?;
    let host = target.host_str().ok_or("目标缺少主机名")?;
    let port = target.port_or_known_default().ok_or("目标端口无效")?;
    let key = format!("{strict}:{}:{host}:{port}", target.scheme());
    {
        let cache = CLIENTS.lock().map_err(|_| "HTTP 客户端锁失败")?;
        if let Some(http) = cached_client(&cache, &key, Instant::now()) {
            return Ok((target, http));
        }
    }
    let addrs = network_policy::resolve_target(&target, strict).await?;
    static BUILDERS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
    let permit = BUILDERS
        .acquire()
        .await
        .map_err(|_| "HTTP client builder unavailable")?;
    let owned_target = target.clone();
    let http = Arc::new(
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            build_client(&owned_target, &addrs)
        })
        .await
        .map_err(|_| "HTTP client builder failed")??,
    );
    let now = Instant::now();
    let mut cache = CLIENTS.lock().map_err(|_| "HTTP 客户端锁失败")?;
    let http = cached_client(&cache, &key, now).unwrap_or(http);
    if !cache.get(&key).is_some_and(|(expires, _)| now < *expires) {
        cache.retain(|_, (expires, _)| now < *expires);
        if cache.len() >= 16 {
            cache.clear();
        }
        cache.insert(key, (now + CLIENT_TTL, http.clone()));
    }
    Ok((target, http))
}

pub fn refresh_client() {
    if let Ok(mut cache) = CLIENTS.lock() {
        cache.clear();
    }
}

/// 不可信 GET 的统一入口；自动重定向被关闭，每一跳重新检查 URL、DNS 并固定解析地址。
pub async fn get(
    raw: &str,
    timeout: Duration,
    accept: Option<&str>,
    referer: Option<&str>,
) -> Result<crate::transport::Response, String> {
    get_request(raw, timeout, accept, referer, None, None, false).await
}

pub(crate) async fn get_media_stream(
    raw: &str,
    referer: &str,
    range: Option<&str>,
) -> Result<crate::transport::Response, String> {
    // Retry only before response headers/bytes are handed to the player.
    // A temporary DNS/connect failure must not become a permanent local 502.
    with_retry(true, || {
        get_request(
            raw,
            Duration::from_secs(20),
            None,
            Some(referer),
            range,
            None,
            true,
        )
    })
    .await
}
async fn get_request(
    raw: &str,
    timeout: Duration,
    accept: Option<&str>,
    referer: Option<&str>,
    range: Option<&str>,
    if_match: Option<&str>,
    streaming: bool,
) -> Result<crate::transport::Response, String> {
    tokio::time::timeout(timeout, async {
        let policy_error = |phase: &str, error: String| {
            crate::playback_log::record("network.target_failed", json!({"resource": crate::playback_log::resource_id(raw), "phase": phase, "error_kind": crate::playback_log::error_kind(&error)}));
            error
        };
        let mut next = network_policy::parse_target(raw).map_err(|e| policy_error("parse", e))?;
        for hop in 0..=5 {
            let resolving = Instant::now();
            let (target, http) = client_for(next.as_str()).await.map_err(|e| policy_error("dns_or_client", e))?;
            crate::playback_log::record("network.target_ready", json!({"resource": crate::playback_log::resource_id(raw), "target_resource": crate::playback_log::resource_id(target.as_str()), "dns_or_client_ms": resolving.elapsed().as_millis() as u64, "hop": hop}));
            let mut request = http.get(target.clone()).timeout(timeout);
            if let Some(etag) = if_match { request = request.header("If-Match", etag); }
            if let Some(value) = accept {
                request = request.header("Accept", value);
            }
            if let Some(value) = referer {
                request = request.header("Referer", value);
            }
            if let Some(range) = range { request = request.header("Range", range); }
            let response = if streaming { request.send_streaming().await } else { request.send().await }.map_err(|e| err_text(&e))?;
            if !matches!(response.status().as_u16(), 301 | 302 | 303 | 307 | 308) {
                return Ok(response);
            }
            if hop == 5 {
                return Err("重定向次数超过限制".into());
            }
            let location = response
                .headers()
                .get(crate::transport::header::LOCATION)
                .and_then(|h| h.to_str().ok())
                .ok_or("重定向缺少有效 Location")?;
            next = network_policy::redirect_target(&target, location).map_err(|e| policy_error("redirect", e))?;
            crate::playback_log::record("network.redirect", json!({"resource": crate::playback_log::resource_id(raw), "from": crate::playback_log::resource_id(target.as_str()), "to": crate::playback_log::resource_id(next.as_str()), "status": response.status().as_u16(), "hop": hop + 1}));
        }
        Err("重定向次数超过限制".into())
    })
    .await
    .map_err(|_| "请求超时".to_string())?
}

/// 只返回代理的协议/主机/端口；解析失败时隐藏整个值，绝不回传认证或查询参数。
pub fn redact_proxy(raw: &str) -> String {
    let parsed = url::Url::parse(raw.trim())
        .ok()
        .filter(|u| u.host_str().is_some());
    match parsed {
        Some(url) => {
            let mut safe = format!("{}://{}", url.scheme(), url.host_str().unwrap());
            if let Some(port) = url.port() {
                safe.push_str(&format!(":{port}"));
            }
            safe
        }
        None => "[已配置，原始值已隐藏]".into(),
    }
}

/// 看起来像代理 / 隧道问题（而不是目标站点本身不可达）。
pub fn is_proxy_error(e: &str) -> bool {
    let e = e.to_ascii_lowercase();
    e.contains("tunnel") || e.contains("proxy")
}

static LAST_HEAL: Lazy<std::sync::Mutex<Option<Instant>>> =
    Lazy::new(|| std::sync::Mutex::new(None));

/// 请求失败后按需重建客户端：代理隧道错误、连接被拒 / 超时都算「网络环境可能变了」。
/// 3 秒内只重建一次，批量探测不会反复重建。
pub fn heal_client(reason: &str) {
    let connectish = reason.contains("Connect")
        || reason.contains("timed out")
        || reason.contains("refused")
        || reason.contains("dns");
    if !is_proxy_error(reason) && !connectish {
        return;
    }
    let mut last = match LAST_HEAL.lock() {
        Ok(l) => l,
        Err(_) => return,
    };
    if let Some(t) = *last
        && t.elapsed() < Duration::from_secs(3)
    {
        return;
    }
    *last = Some(Instant::now());
    drop(last);
    refresh_client();
}

/// Flatten transport errors for diagnostics.
pub fn err_text(e: &crate::transport::Error) -> String {
    let mut out = e.to_string();
    let mut src = std::error::Error::source(e);
    while let Some(s) = src {
        let t = s.to_string();
        if !t.is_empty() && !out.contains(&t) {
            out.push_str(" ← ");
            out.push_str(&t);
        }
        src = s.source();
    }
    out
}

fn dns_summary(addrs: impl IntoIterator<Item = SocketAddr>) -> Value {
    let mut ips: Vec<_> = addrs.into_iter().map(|addr| addr.ip()).collect();
    ips.sort_unstable();
    ips.dedup();
    let has_fake_ip = ips.iter().any(|ip| {
        let v4 = match ip {
            std::net::IpAddr::V4(v4) => Some(*v4),
            std::net::IpAddr::V6(v6) => v6.to_ipv4_mapped(),
        };
        v4.is_some_and(|ip| {
            let [a, b, _, _] = ip.octets();
            a == 198 && (b == 18 || b == 19)
        })
    });
    json!({ "count": ips.len(), "has_fake_ip": has_fake_ip })
}

/// 网络自检：DNS / HTTP / 代理相关环境变量，用于远程定位「打不开」。
pub async fn diagnose() -> Value {
    let cur = base();
    let host = url::Url::parse(&cur)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_string()))
        .unwrap_or_default();

    // fake-ip（198.18.0.0/15）说明 DNS 被 TUN 接管：关掉 TUN 后这个地址根本不可路由。
    let dns = match crate::dns::lookup(&host, 443).await {
        Ok(addresses) => dns_summary(addresses),
        Err(error) => json!({ "error": error }),
    };

    let http = probe_content(&cur, Duration::from_secs(20)).await;

    json!({
        "base": cur,
        "host": host,
        "dns": dns,
        "resolver": crate::dns::diagnostics(),
        "transport": {"library": "Reqwest 0.12 / Rustls 0.23 (crates.io)", "pinned_direct": true, "address_fallback": true, "proxy": true, "upstream_streaming": true, "media_streams": 2, "media_chunk_bytes": 32768, "max_response_bytes": 8 * 1024 * 1024, "max_in_flight": 4, "max_idle_per_origin": 2},
        "http": http,
        "env": {
            "HTTP_PROXY": std::env::var("HTTP_PROXY").ok().map(|p| redact_proxy(&p)),
            "HTTPS_PROXY": std::env::var("HTTPS_PROXY").ok().map(|p| redact_proxy(&p)),
            "ALL_PROXY": std::env::var("ALL_PROXY").ok().map(|p| redact_proxy(&p)),
            "NO_PROXY": std::env::var("NO_PROXY").ok().map(|_| "[已配置，列表已隐藏]"),
            "HEDONE_PROXY": std::env::var("HEDONE_PROXY").ok().map(|p| redact_proxy(&p)),
        },
    })
}

/// A reachable landing page does not establish that a line serves content.
/// Probe the same guest envelope as discovery, without credentials or writes.
pub(crate) async fn probe_content(origin: &str, timeout: Duration) -> Value {
    let started = Instant::now();
    let result = tokio::time::timeout(
        timeout,
        edge(origin, "GET", "/api/videos?page=1&size=24", None, None),
    )
    .await
    .unwrap_or_else(|_| Err("内容接口检测超时".into()));
    content_probe_result(result, started.elapsed().as_millis() as u64)
}

fn content_probe_result(result: Result<Value, String>, ms: u64) -> Value {
    match result {
        Ok(value) if value.get("items").and_then(Value::as_array).is_some() => {
            json!({"ok": true, "probe": "content_api", "ms": ms})
        }
        Ok(_) => json!({"ok": false, "probe": "content_api", "ms": ms,
            "error": "内容接口返回了无法识别的数据"}),
        Err(error) => {
            let status = error
                .strip_prefix("HTTP ")
                .and_then(|s| s.split_whitespace().next())
                .and_then(|s| s.parse::<u16>().ok())
                .filter(|code| (100..600).contains(code));
            if let Some(status) = status {
                json!({"ok": false, "probe": "content_api", "ms": ms, "status": status})
            } else {
                json!({"ok": false, "probe": "content_api", "ms": ms, "error": error})
            }
        }
    }
}

fn retryable_error(error: &str) -> bool {
    if let Some(message) = error.strip_prefix("上游接口失败：") {
        return message == "获取视频列表失败";
    }
    if error == "401" || error.contains("当前 Courierust") {
        return false;
    }
    if let Some(status) = error
        .strip_prefix("HTTP ")
        .and_then(|s| s.split_whitespace().next())
        .and_then(|s| s.parse::<u16>().ok())
    {
        return matches!(status, 408 | 425 | 429 | 500..=599);
    }
    !matches!(
        crate::playback_log::error_kind(error),
        "https_downgrade_denied"
            | "private_address_denied"
            | "target_policy_denied"
            | "redirect_error"
    )
}

fn decode_edge_response(value: Value) -> Result<Value, String> {
    if value.is_null() {
        return Ok(Value::Null);
    }
    if value.get("status").and_then(Value::as_i64) == Some(1) {
        return Ok(value.get("data").cloned().unwrap_or(Value::Null));
    }
    let message = value
        .get("msg")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .unwrap_or("接口返回失败");
    Err(format!(
        "上游接口失败：{}",
        message.chars().take(220).collect::<String>()
    ))
}

/// 只重试可能恢复的错误；404/权限错误/安全拒绝直接结束，避免无效等待。
/// 可恢复的传输错误重建地址配置后重试；库能力限制不重试。
async fn with_retry<F, Fut, T>(retry: bool, mut f: F) -> Result<T, String>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    let mut last = String::from("network error");
    let attempts = if retry { 3 } else { 1 };
    for attempt in 0..attempts {
        match f().await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last = e;
                if !retryable_error(&last) {
                    return Err(last);
                }
                heal_client(&last);
                if attempt + 1 < attempts {
                    tokio::time::sleep(Duration::from_millis(350 * (attempt as u64 + 1))).await;
                }
            }
        }
    }
    Err(last)
}

// 只记录固定的操作类型，不写搜索词、账号、内容 ID 或查询参数。
fn edge_operation(path: &str) -> &'static str {
    let path = path.split('?').next().unwrap_or("");
    if path.starts_with("/api/videos/category/") {
        "category"
    } else if path.starts_with("/api/videos/")
        && (path.ends_with("/play") || path.ends_with("/playback"))
    {
        "play"
    } else if path == "/api/videos" {
        "feed"
    } else if path.starts_with("/api/videos/") {
        "video"
    } else if path == "/api/posts" {
        "posts"
    } else if path.starts_with("/api/posts/") {
        "post"
    } else if path.starts_with("/api/ranks/") {
        "rank"
    } else if path == "/api/search" {
        "search"
    } else if path.starts_with("/api/account/") {
        "account"
    } else {
        "other"
    }
}

/// 仅无请求体、无凭据的逻辑 GET 可以迁移网关；信封本身仍使用 POST。
fn edge_redirect_target(
    current: &url::Url,
    status: u16,
    location: &str,
    guest_get: bool,
) -> Result<url::Url, String> {
    if !guest_get || !matches!(status, 301..=303) {
        return Err("业务接口重定向已拒绝".into());
    }
    network_policy::redirect_target(current, location)
}

/// 业务请求：走边缘信封。
pub async fn edge(
    origin: &str,
    method: &str,
    path: &str,
    body: Option<Value>,
    token: Option<&str>,
) -> Result<Value, String> {
    let cur = normalize_base(origin).ok_or("业务请求必须使用安全 HTTPS 线路")?;
    if (token.is_some()
        || matches!(
            path,
            "/api/account/loginByPassword" | "/api/account/registerByPassword"
        ))
        && !trusted_auth_origin(&cur)
    {
        return Err("镜像线路仅供游客浏览；登录/注册请切换到固定线路".into());
    }
    let (encoded, ctype) = match &body {
        Some(v) => (
            B64.encode(nextjson::to_vec(v).map_err(|e| e.to_string())?),
            "application/json",
        ),
        None => (String::new(), ""),
    };
    let envelope = json!({
        "method": method,
        "path": path,
        "body": encoded,
        "content_type": ctype,
    });

    let url = format!("{cur}/api/edge/request");
    let referer = format!("{cur}/");
    let token = token.map(|s| s.to_string());

    static NEXT_EDGE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let request = NEXT_EDGE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let line_host = url::Url::parse(&cur)
        .unwrap()
        .host_str()
        .unwrap()
        .to_string();
    let operation = edge_operation(path);
    let mut attempt = 0;
    let guest_get = method.eq_ignore_ascii_case("GET") && body.is_none() && token.is_none();
    // 取播放地址的 POST 没有副作用，和 GET 一样允许重试
    let can_retry = (method.eq_ignore_ascii_case("GET") && body.is_none())
        || (method.eq_ignore_ascii_case("POST") && operation == "play");
    with_retry(can_retry, || {
        attempt += 1;
        let attempt = attempt;
        let envelope = envelope.clone();
        let token = token.clone();
        let url = url.clone();
        let referer = referer.clone();
        let line_host = line_host.clone();
        async move {
            let started = Instant::now();
            crate::playback_log::record("api.begin", json!({"request": request, "attempt": attempt, "operation": operation, "method": method, "line_host": line_host}));
            let mut status_code = None;
            let mut headers_ms = None;
            let mut target_host = line_host.clone();
            let mut response_kind = "unknown";
            let mut gateway = "other";
            let result = async {
                let mut next = network_policy::parse_target(&url)?;
                for hop in 0..=5 {
                    let (target, client) = client_for(next.as_str()).await?;
                    target_host = target.host_str().unwrap_or("").to_string();
                    let mut req = client
                        .post(target.clone())
                        .header("Accept", "application/json")
                        .header("Referer", &referer)
                        .header("content-type", "application/json").body(envelope.to_string());
                    if let Some(t) = token.as_deref()
                        && !t.is_empty() {
                            req = req.header("Authorization", format!("Bearer {t}"));
                        }
                    let resp = req.send().await.map_err(|e| err_text(&e))?;
                    let status = resp.status();
                    status_code = Some(status.as_u16());
                    headers_ms = Some(started.elapsed().as_millis() as u64);
                    let ctype = resp.headers().get(crate::transport::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("");
                    response_kind = if ctype.contains("json") { "json" } else if ctype.contains("html") { "html" } else { "other" };
                    gateway = if resp.headers().contains_key("x-amz-cf-id") { "cloudfront" } else if resp.headers().contains_key("cf-ray") { "cloudflare" } else { "other" };
                    if status.is_redirection() {
                        if hop == 5 {
                            return Err("重定向次数超过限制".into());
                        }
                        let location = resp
                            .headers()
                            .get(crate::transport::header::LOCATION)
                            .and_then(|h| h.to_str().ok())
                            .ok_or("重定向缺少有效 Location")?;
                        next = edge_redirect_target(&target, status.as_u16(), location, guest_get)?;
                        continue;
                    }
                    let bytes = read_limited(resp, 8 * 1024 * 1024).await?;
                    let text = String::from_utf8(bytes).map_err(|_| "接口响应不是 UTF-8")?;
                    if status.as_u16() == 401 || status.as_u16() == 403 {
                        return Err("401".to_string());
                    }
                    if !status.is_success() {
                        return Err(format!(
                            "HTTP {status}: {}",
                            text.chars().take(160).collect::<String>()
                        ));
                    }
                    if text.trim().is_empty() {
                        return Ok(Value::Null);
                    }
                    return nextjson::from_str::<Value>(&text)
                        .map_err(|e| format!("{e}: {}", text.chars().take(160).collect::<String>()));
                }
                Err("重定向次数超过限制".into())
            }.await;
            let business_status = result.as_ref().ok().and_then(|v: &Value| v.get("status")).and_then(Value::as_i64);
            // Decode before retry/logging: transport success is not business success.
            let result = result.and_then(decode_edge_response);
            crate::playback_log::record("api.end", json!({
                "request": request, "attempt": attempt, "operation": operation, "method": method,
                "line_host": line_host, "target_host": target_host, "status": status_code,
                "headers_ms": headers_ms, "elapsed_ms": started.elapsed().as_millis() as u64,
                "response_kind": response_kind, "gateway": gateway,
                "business_status": business_status,
                "error_kind": result.as_ref().err().map(|e: &String| crate::playback_log::error_kind(e)),
                "retryable": can_retry && result.as_ref().err().is_some_and(|e| retryable_error(e)),
            }));
            result
        }
    })
    .await
}

/// 拉原始字节（图片 / m3u8 / 分片）。
pub async fn fetch_bytes(url: &str) -> Result<(Option<String>, Vec<u8>), String> {
    let resource = fetch_resource(url).await?;
    Ok((resource.mime, resource.bytes))
}

pub(crate) struct Resource {
    pub mime: Option<String>,
    pub url: String,
    pub bytes: Vec<u8>,
}

pub(crate) async fn fetch_resource(url: &str) -> Result<Resource, String> {
    static NEXT_REQUEST: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let request = NEXT_REQUEST.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let resource = crate::playback_log::resource_id(url);
    let mut attempt = 0;
    let url = url.to_string();
    let referer = format!("{}/", base());
    with_retry(true, || {
        attempt += 1;
        let attempt = attempt;
        let resource = resource.clone();
        let url = url.clone();
        let referer = referer.clone();
        async move {
            let started = Instant::now();
            crate::playback_log::record("network.begin", json!({"request": request, "resource": resource, "attempt": attempt}));
            let mut status = None;
            let mut headers_ms = None;
            let result = async {
                let resp = get(&url, Duration::from_secs(20), None, Some(&referer)).await?;
                status = Some(resp.status().as_u16());
                headers_ms = Some(started.elapsed().as_millis() as u64);
                if !resp.status().is_success() {
                    return Err(format!("HTTP {}", resp.status()));
                }
                let ctype = resp
                    .headers()
                    .get(crate::transport::header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .map(|s| s.to_string());
                let resolved = resp.url().to_string();
                let bytes = read_limited(resp, 32 * 1024 * 1024).await?;
                Ok(Resource { mime: ctype, url: resolved, bytes })
            }.await;
            crate::playback_log::record("network.end", json!({"request": request, "resource": resource, "attempt": attempt, "status": status, "headers_ms": headers_ms, "elapsed_ms": started.elapsed().as_millis() as u64, "bytes": result.as_ref().ok().map(|r| r.bytes.len()), "error_kind": result.as_ref().err().map(|e: &String| crate::playback_log::error_kind(e))}));
            result
        }
    })
    .await
}

pub async fn read_limited(
    mut response: crate::transport::Response,
    limit: usize,
) -> Result<Vec<u8>, String> {
    if response.content_length().is_some_and(|n| n > limit as u64) {
        return Err("响应超过大小限制".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| err_text(&e))? {
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err("响应超过大小限制".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn business_failures_retry_only_transient_reads_and_remain_bounded() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        for (retry, message, recover, expected) in [
            (true, "获取视频列表失败", true, 2),
            (true, "获取视频列表失败", false, 3),
            (false, "获取视频列表失败", true, 1),
            (true, "请先登录", true, 1),
            (true, "参数错误", true, 1),
        ] {
            let calls = AtomicUsize::new(0);
            let result = with_retry(retry, || {
                let attempt = calls.fetch_add(1, Ordering::SeqCst);
                async move {
                    decode_edge_response(if recover && attempt > 0 {
                        json!({"status": 1, "data": {"items": [{"id": 42}]}})
                    } else {
                        json!({"status": 0, "msg": message})
                    })
                }
            })
            .await;
            assert_eq!(calls.load(Ordering::SeqCst), expected);
            if recover && expected == 2 {
                assert_eq!(result.unwrap()["items"][0]["id"], json!(42));
            } else {
                let error = result.unwrap_err();
                assert_eq!(
                    crate::playback_log::error_kind(&error),
                    "upstream_business_error"
                );
                assert_eq!(content_probe_result(Err(error), 1)["ok"], json!(false));
            }
        }
    }

    #[test]
    fn content_probe_requires_a_list_and_preserves_failure_categories() {
        assert_eq!(
            content_probe_result(Ok(json!({"items": []})), 7)["ok"],
            json!(true)
        );
        assert_eq!(
            content_probe_result(Ok(json!({"message": "welcome"})), 7)["ok"],
            json!(false)
        );
        let missing =
            content_probe_result(Err("HTTP 404 Not Found: <html>landing</html>".into()), 7);
        assert_eq!(missing["status"], json!(404));
        assert_eq!(missing["ok"], json!(false));
        assert!(!missing.to_string().contains("<html>"));
        let tls = content_probe_result(
            Err("TLS certificate error: no trusted root found".into()),
            7,
        );
        assert_eq!(tls["ok"], json!(false));
        assert!(
            tls["error"]
                .as_str()
                .unwrap()
                .contains("no trusted root found")
        );
    }

    #[tokio::test]
    async fn terminal_errors_do_not_retry_but_transient_failures_can_recover() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        for error in [
            "HTTP 404 Not Found: <html>nginx</html>",
            "HTTP 403 Forbidden",
            "401",
            "禁止访问内网",
            "重定向次数超过限制",
        ] {
            let calls = AtomicUsize::new(0);
            assert!(
                with_retry(true, || async {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Err::<(), _>(error.to_string())
                })
                .await
                .is_err()
            );
            assert_eq!(calls.load(Ordering::SeqCst), 1, "{error}");
        }
        for error in ["HTTP 503 Service Unavailable", "请求超时"] {
            let calls = AtomicUsize::new(0);
            let value = with_retry(true, || {
                let attempt = calls.fetch_add(1, Ordering::SeqCst);
                async move {
                    if attempt == 0 {
                        Err(error.to_string())
                    } else {
                        Ok(42)
                    }
                }
            })
            .await
            .unwrap();
            assert_eq!(value, 42);
            assert_eq!(calls.load(Ordering::SeqCst), 2);
        }
    }

    #[test]
    fn api_operation_labels_exclude_user_input() {
        for (path, expected) in [
            ("/api/videos?page=1&size=10", "feed"),
            ("/api/videos/category/private?x=secret", "category"),
            ("/api/videos/42/play?ep=1", "play"),
            ("/api/videos/42/episodes/1/playback", "play"),
            ("/api/search?q=private-search", "search"),
            ("/api/account/loginByPassword", "account"),
            ("/unknown/private", "other"),
        ] {
            assert_eq!(edge_operation(path), expected);
        }
    }

    #[tokio::test]
    async fn non_idempotent_operations_are_attempted_once() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        for (retry, expected) in [(false, 1), (true, 3)] {
            let calls = AtomicUsize::new(0);
            let result = with_retry(retry, || async {
                calls.fetch_add(1, Ordering::SeqCst);
                Err::<(), _>("rejected".to_string())
            })
            .await;
            assert!(result.is_err());
            assert_eq!(calls.load(Ordering::SeqCst), expected);
        }
    }

    #[test]
    fn dns_diagnostics_only_expose_counts_and_fake_ip_presence() {
        let addrs: Vec<SocketAddr> = ["10.0.0.1:443", "198.18.0.2:443", "[::ffff:198.18.0.3]:443"]
            .into_iter()
            .map(|raw| raw.parse().unwrap())
            .collect();
        let summary = dns_summary(addrs);
        assert_eq!(summary, json!({"count": 3, "has_fake_ip": true}));
        assert!(!summary.to_string().contains("10.0.0.1"));
        assert!(!summary.to_string().contains("198.18"));
        assert_eq!(
            dns_summary(Vec::<SocketAddr>::new()),
            json!({"count":0,"has_fake_ip":false})
        );
    }

    #[test]
    fn pinned_clients_expire_without_extending_the_dns_ttl() {
        let now = Instant::now();
        let client = Arc::new(crate::transport::Client::new());
        let mut cache = ClientCache::new();
        cache.insert(
            "true:example.com:443".into(),
            (now + CLIENT_TTL, client.clone()),
        );
        assert!(Arc::ptr_eq(
            &cached_client(
                &cache,
                "true:example.com:443",
                now + Duration::from_secs(29)
            )
            .unwrap(),
            &client
        ));
        assert!(cached_client(&cache, "true:example.com:443", now + CLIENT_TTL).is_none());
        assert!(cached_client(&cache, "false:example.com:443", now).is_none());
        assert!(cached_client(&cache, "true:example.com:8443", now).is_none());
    }

    #[test]
    fn edge_redirects_only_replay_anonymous_reads() {
        let current = url::Url::parse("https://huangguoai.ai/api/edge/request").unwrap();
        assert_eq!(
            edge_redirect_target(
                &current,
                301,
                "https://huangguoai.com/api/edge/request",
                true
            )
            .unwrap()
            .host_str(),
            Some("huangguoai.com")
        );
        assert!(edge_redirect_target(&current, 302, "/next", true).is_ok());
        for status in [301, 302, 303, 307, 308] {
            assert!(edge_redirect_target(&current, status, "/next", false).is_err());
        }
        for status in [307, 308] {
            assert!(edge_redirect_target(&current, status, "/next", true).is_err());
        }
        assert!(edge_redirect_target(&current, 301, "http://example.com/", true).is_err());
        assert!(edge_redirect_target(&current, 301, "https://127.0.0.1/", true).is_err());
    }

    #[test]
    fn proxy_credentials_and_query_are_redacted() {
        assert_eq!(
            redact_proxy("http://alice:p%40ss@127.0.0.1:7897/path?token=secret#hidden"),
            "http://127.0.0.1:7897"
        );
        assert_eq!(
            redact_proxy("socks5://alice:secret@[::1]:1080"),
            "socks5://[::1]:1080"
        );
        for raw in ["alice:secret@127.0.0.1:7897", "not a url secret", ""] {
            assert_eq!(redact_proxy(raw), "[已配置，原始值已隐藏]");
        }
    }

    #[test]
    fn base_requires_https_origin_and_auth_trust_is_static() {
        assert_eq!(
            normalize_base("https://HUANGGUOAI.COM:443/"),
            Some(DEFAULT_BASE.into())
        );
        for raw in [
            "http://huangguoai.com",
            "https://user:pass@huangguoai.com",
            "https://huangguoai.com/path",
            "https://huangguoai.com/?secret=1",
            "https://huangguoai.com/#fragment",
            "https://192.168.1.1",
        ] {
            assert_eq!(normalize_base(raw), None, "{raw}");
        }
        assert!(trusted_auth_origin(DEFAULT_BASE));
        assert!(trusted_auth_origin("https://huangguoai.ai"));
        assert!(!trusted_auth_origin("https://mirror.example"));
        assert!(!trusted_auth_origin("https://huangguoai.com.evil.example"));
    }

    #[tokio::test]
    async fn untrusted_origins_reject_credentials_before_network() {
        for (path, body, token) in [
            (
                "/api/account/loginByPassword",
                Some(json!({"password":"secret"})),
                None,
            ),
            (
                "/api/account/registerByPassword",
                Some(json!({"password":"secret"})),
                None,
            ),
            ("/api/videos", None, Some("secret-token")),
        ] {
            let err = edge("https://mirror.invalid", "POST", path, body, token)
                .await
                .unwrap_err();
            assert!(err.contains("镜像线路仅供游客浏览"));
        }
    }

    #[tokio::test]
    async fn private_get_is_rejected_before_network() {
        let err = get(
            "http://127.0.0.1:1/private",
            Duration::from_secs(1),
            None,
            None,
        )
        .await
        .unwrap_err();
        assert!(err.contains("禁止访问"));
    }

    /// 手动跑：`cargo test --lib -- --ignored net::tests::diag -- --nocapture`
    /// 关掉 TUN、只留系统代理时跑一遍，能直接看出客户端有没有走代理。
    #[tokio::test]
    #[ignore = "联网测试：请求上游做网络自检，手动用 --ignored 运行"]
    async fn diag() {
        println!(
            "{}",
            nextjson::to_string_pretty(&diagnose().await).expect("json")
        );
    }
}

// End of network regression tests.
