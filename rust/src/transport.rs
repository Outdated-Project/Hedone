//! Bounded adapter using only public APIs from the published Courierust crate.
//! HTTP/1 responses are buffered by the library; chunk() does not stream upstream.
use crate::transport_connection::{Connections, remaining};
pub use axum::http::header;
use axum::{
    body::Bytes,
    http::{HeaderMap, HeaderName, HeaderValue, StatusCode},
};
use courierust::{
    courierust_body::Body,
    courierust_client::ClientConfig,
    courierust_http::{Method, request::Request as HttpRequest},
    courierust_tls::RootStore,
};
use std::{
    io,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Semaphore, SemaphorePermit};
pub type Error = io::Error;
const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_TIMEOUT: Duration = Duration::from_secs(20);
static WORKERS: Semaphore = Semaphore::const_new(4);
fn error(e: impl std::fmt::Display) -> Error {
    io::Error::other(e.to_string())
}

#[derive(Clone)]
pub struct Client {
    origin: url::Origin,
    connections: Arc<Connections>,
    roots: Arc<RootStore>,
}
impl Client {
    pub fn create(
        target: &url::Url,
        addresses: &[SocketAddr],
        proxy: Option<String>,
    ) -> Result<Self, String> {
        if proxy.is_some() {
            return Err("当前 Courierust 地址固定模式不支持代理；不会绕过已配置的代理直连".into());
        }
        if !matches!(target.scheme(), "http" | "https")
            || !target.username().is_empty()
            || target.password().is_some()
        {
            return Err("HTTP 目标无效".into());
        }
        let connections = Connections::new(
            addresses,
            target.port_or_known_default().ok_or("目标端口无效")?,
        )?;
        let roots = courierust::courierust_tls::system_roots::load()
            .or_else(|_| {
                let mut roots = RootStore::new();
                roots.add_pem(include_str!("../assets/cacert.pem"))?;
                Ok::<_, courierust::courierust_tls::TlsError>(roots)
            })
            .map_err(|_| "无法读取 TLS 信任库")?;
        Ok(Self {
            origin: target.origin(),
            connections: Arc::new(connections),
            roots: Arc::new(roots),
        })
    }
    #[cfg(test)]
    pub fn new() -> Self {
        Self::create(
            &url::Url::parse("http://localhost").unwrap(),
            &["127.0.0.1:80".parse().unwrap()],
            None,
        )
        .unwrap()
    }
    pub fn get(&self, url: impl ToString) -> Request {
        self.request(url, Method::GET)
    }
    pub fn post(&self, url: impl ToString) -> Request {
        self.request(url, Method::POST)
    }
    fn request(&self, url: impl ToString, method: Method) -> Request {
        Request {
            client: self.clone(),
            url: url.to_string(),
            method,
            headers: vec![],
            body: String::new(),
            timeout: MAX_TIMEOUT,
        }
    }
}
pub struct Request {
    client: Client,
    url: String,
    method: Method,
    headers: Vec<(String, String)>,
    body: String,
    timeout: Duration,
}
impl Request {
    pub fn header(mut self, name: impl ToString, value: impl ToString) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }
    pub fn body(mut self, body: String) -> Self {
        self.body = body;
        self
    }
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }
    pub async fn send(self) -> Result<Response, Error> {
        let url = url::Url::parse(&self.url).map_err(error)?;
        if url.origin() != self.client.origin
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return Err(error("拒绝未固定地址的请求来源"));
        }
        let timeout = self.timeout.min(MAX_TIMEOUT);
        let deadline = Instant::now() + timeout;
        tokio::time::timeout(timeout, async move {
            let permit = WORKERS.acquire().await.map_err(error)?;
            tokio::task::spawn_blocking(move || {
                let mut config = ClientConfig {
                    max_redirects: 0,
                    max_body: MAX_BODY,
                    max_header_list: 65536,
                    user_agent: Some(crate::net::UA.into()),
                    accept_encoding: false,
                    connect_timeout: Some(remaining(deadline)?),
                    handshake_timeout: Some(remaining(deadline)?),
                    read_timeout: Some(remaining(deadline)?),
                    ..Default::default()
                };
                let hostname = match url.host().ok_or_else(|| error("missing hostname"))? {
                    url::Host::Domain(name) => name.to_owned(),
                    url::Host::Ipv4(ip) => ip.to_string(),
                    url::Host::Ipv6(ip) => ip.to_string(),
                };
                let mut request = HttpRequest::<Body>::new(
                    self.method,
                    courierust::courierust_http::PathAndQuery::from_bytes(
                        url[url::Position::BeforePath..url::Position::AfterQuery].as_bytes(),
                    )
                    .map_err(error)?,
                );
                for (name, value) in self.headers {
                    request = request.header(
                        courierust::courierust_http::HeaderName::from_bytes(name.as_bytes())
                            .map_err(error)?,
                        courierust::courierust_http::HeaderValue::from_bytes(value.as_bytes())
                            .map_err(error)?,
                    );
                }
                request = request.header("accept-encoding", "identity");
                if !self.body.is_empty() {
                    request = request.with_body(Body::from(self.body));
                }
                let roots = (url.scheme() == "https").then_some(self.client.roots.as_ref());
                let pooled = self.client.connections.take();
                let reused = pooled.is_some();
                let mut connection = match pooled {
                    Some(connection) => connection,
                    None => self
                        .client
                        .connections
                        .connect(&hostname, roots, &config, deadline)?,
                };
                config.read_timeout = Some(remaining(deadline)?);
                connection
                    .set_read_deadline(config.read_timeout)
                    .map_err(error)?;
                let mut result = connection.send(
                    &request,
                    &config,
                    &url[url::Position::BeforeHost..url::Position::AfterPort],
                    false,
                );
                // Retry only an idempotent GET on a reused socket that closed
                // without any response bytes. Never replay a POST or a partial response.
                if reused
                    && request.method == Method::GET
                    && result
                        .as_ref()
                        .is_err_and(|e| connection.is_stale_failure(e))
                {
                    drop(connection);
                    connection = self
                        .client
                        .connections
                        .connect(&hostname, roots, &config, deadline)?;
                    config.read_timeout = Some(remaining(deadline)?);
                    connection
                        .set_read_deadline(config.read_timeout)
                        .map_err(error)?;
                    result = connection.send(
                        &request,
                        &config,
                        &url[url::Position::BeforeHost..url::Position::AfterPort],
                        false,
                    );
                }
                let response = result.map_err(|e| {
                    if e.to_string().contains("body exceeds limit") {
                        error("当前 Courierust 响应超过 8 MiB 上限，不支持大文件流式传输")
                    } else {
                        error(e)
                    }
                })?;
                let status = StatusCode::from_u16(response.status.as_u16()).map_err(error)?;
                let mut headers = HeaderMap::new();
                for (name, value) in response.headers.iter() {
                    headers.append(
                        HeaderName::from_bytes(name.as_str().as_bytes()).map_err(error)?,
                        HeaderValue::from_bytes(value.as_bytes()).map_err(error)?,
                    );
                }
                if headers
                    .get("content-encoding")
                    .is_some_and(|v| v != "identity")
                {
                    return Err(error("unsupported unsolicited content encoding"));
                }
                let body = match response.body {
                    Body::Empty => Bytes::new(),
                    Body::Bytes(bytes) => Bytes::from(bytes.into_vec()),
                    _ => return Err(error("unexpected streaming body from buffered HTTP/1 API")),
                };
                self.client.connections.recycle(connection);
                Ok(Response {
                    status,
                    headers,
                    url,
                    body,
                    permit: Some(permit),
                })
            })
            .await
            .map_err(error)?
        })
        .await
        .map_err(|_| error("request timed out"))?
    }
}
#[derive(Debug)]
pub struct Response {
    status: StatusCode,
    headers: HeaderMap,
    url: url::Url,
    body: Bytes,
    // Keep admission until the buffered response is consumed or dropped.
    // Cancellation never frees a still-running blocking worker's permit.
    permit: Option<SemaphorePermit<'static>>,
}
impl Response {
    pub fn status(&self) -> StatusCode {
        self.status
    }
    pub fn headers(&self) -> &HeaderMap {
        &self.headers
    }
    pub fn url(&self) -> &url::Url {
        &self.url
    }
    pub fn content_length(&self) -> Option<u64> {
        self.headers
            .get("content-length")?
            .to_str()
            .ok()?
            .parse()
            .ok()
    }
    pub(crate) fn buffered_len(&self) -> usize {
        self.body.len()
    }
    pub async fn chunk(&mut self) -> Result<Option<Bytes>, Error> {
        if self.body.is_empty() {
            self.permit.take();
            return Ok(None);
        }
        Ok(Some(self.body.split_to(self.body.len().min(32768))))
    }
    pub fn bytes_stream(self) -> impl futures_util::Stream<Item = Result<Bytes, Error>> {
        futures_util::stream::unfold(self, |mut response| async move {
            match response.chunk().await {
                Ok(Some(bytes)) => Some((Ok(bytes), response)),
                Ok(None) => None,
                Err(e) => Some((Err(e), response)),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    #[test]
    fn official_certificate_path_limitation_and_invalid_certificates() {
        use courierust::courierust_tls::x509::validate_chain;
        let mut roots = courierust::courierust_tls::RootStore::new();
        roots.add_pem(include_str!("../assets/cacert.pem")).unwrap();
        let chain = vec![
            include_bytes!("../tests/fixtures/cross_signed/leaf.der").to_vec(),
            include_bytes!("../tests/fixtures/cross_signed/intermediate.der").to_vec(),
            include_bytes!("../tests/fixtures/cross_signed/cross-signed-root.der").to_vec(),
        ];
        // Fixed capture time keeps the regression independent of leaf renewal.
        let now = 1_794_355_200;
        // Official 1.1.2 cannot terminate this cross-signed chain at the earlier anchor.
        assert!(validate_chain(&roots, &chain, now).is_err());
        validate_chain(&roots, &chain[..2], now).unwrap();
        assert!(
            validate_chain(&courierust::courierust_tls::RootStore::new(), &chain, now).is_err()
        );
        assert!(validate_chain(&roots, &chain[..2], now + 365 * 86400).is_err());
        let mut tampered = chain[..2].to_vec();
        *tampered[0].last_mut().unwrap() ^= 1;
        assert!(validate_chain(&roots, &tampered, now).is_err());
    }
    #[tokio::test]
    #[ignore = "direct HTTPS probe, independent of OS proxy, using mobile fallback roots"]
    async fn live_bundled_roots_validate_primary_origin() {
        let target = url::Url::parse(crate::net::DEFAULT_BASE).unwrap();
        let addresses = crate::dns::lookup(target.host_str().unwrap(), 443)
            .await
            .unwrap();
        // This probes the direct adapter, not proxy selection or application routing.
        let mut client = Client::create(&target, &addresses, None).unwrap();
        let mut roots = RootStore::new();
        roots.add_pem(include_str!("../assets/cacert.pem")).unwrap();
        client.roots = Arc::new(roots);
        for _ in 0..3 {
            let response = client.get(&target).send().await.unwrap();
            assert!(response.status().is_success());
        }
    }
    #[tokio::test]
    #[ignore = "live upstream playback API; set HGHUB_TEST_VIDEO_ID"]
    async fn live_manifest_can_reopen_same_origin() {
        let id = std::env::var("HGHUB_TEST_VIDEO_ID")
            .unwrap()
            .parse()
            .unwrap();
        let api = crate::api::Api::new();
        let play = crate::api::api_play(&api, id, 1).await.unwrap();
        let url = play["video_url"].as_str().unwrap();
        for _ in 0..3 {
            let response = crate::net::get_media_range(
                url,
                &format!("{}/", crate::net::base()),
                "bytes=0-",
                None,
            )
            .await
            .unwrap();
            let bytes = crate::net::read_limited(response, 2 * 1024 * 1024)
                .await
                .unwrap();
            assert!(bytes.starts_with(b"#EXTM3U"));
        }
    }
    fn head(socket: &mut std::net::TcpStream) -> String {
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            socket.read_exact(&mut byte).unwrap();
            bytes.push(byte[0]);
            assert!(bytes.len() < 8192);
        }
        String::from_utf8(bytes).unwrap()
    }
    #[tokio::test]
    async fn refused_pinned_address_falls_back_without_resolving_the_origin() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let failed = SocketAddr::new("127.0.0.2".parse().unwrap(), address.port());
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            assert!(head(&mut socket).contains("unresolvable.invalid"));
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                .unwrap();
        });
        let target =
            url::Url::parse(&format!("http://unresolvable.invalid:{}", address.port())).unwrap();
        let client = Client::create(&target, &[failed, address], None).unwrap();
        let response = client
            .get(&target)
            .timeout(Duration::from_secs(6))
            .send()
            .await
            .unwrap();
        assert_eq!(crate::net::read_limited(response, 16).await.unwrap(), b"ok");
        server.join().unwrap();
    }
    #[tokio::test]
    async fn sequential_requests_reuse_one_connection_without_carrying_headers() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let first = head(&mut socket).to_lowercase();
            assert!(first.starts_with("get /first?x=1 "));
            assert!(first.contains("authorization: bearer first"));
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none")
                .unwrap();
            let second = head(&mut socket).to_lowercase();
            assert!(second.starts_with("get /second "));
            assert!(!second.contains("authorization"));
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\ntwo")
                .unwrap();
        });
        let origin = url::Url::parse(&format!("http://{address}")).unwrap();
        let client = Client::create(&origin, &[address], None).unwrap();
        let response = client
            .get(origin.join("first?x=1").unwrap())
            .header("Authorization", "Bearer first")
            .timeout(Duration::from_secs(3))
            .send()
            .await
            .unwrap();
        assert_eq!(
            crate::net::read_limited(response, 16).await.unwrap(),
            b"one"
        );
        let response = client
            .get(origin.join("second").unwrap())
            .timeout(Duration::from_secs(3))
            .send()
            .await
            .unwrap();
        assert_eq!(
            crate::net::read_limited(response, 16).await.unwrap(),
            b"two"
        );
        server.join().unwrap();
    }
    #[tokio::test]
    async fn pooled_post_is_not_replayed_after_server_consumes_request() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server_listener = listener.try_clone().unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = server_listener.accept().unwrap();
            head(&mut socket);
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .unwrap();
            assert!(head(&mut socket).starts_with("POST / "));
            let mut payload = [0; 6];
            socket.read_exact(&mut payload).unwrap();
            assert_eq!(&payload, b"change");
            // Simulate an upstream applying a write, then losing its response.
        });
        let origin = url::Url::parse(&format!("http://{address}")).unwrap();
        let client = Client::create(&origin, &[address], None).unwrap();
        let response = client.get(&origin).send().await.unwrap();
        crate::net::read_limited(response, 16).await.unwrap();
        assert!(
            client
                .post(&origin)
                .body("change".into())
                .timeout(Duration::from_secs(3))
                .send()
                .await
                .is_err()
        );
        server.join().unwrap();
        listener.set_nonblocking(true).unwrap();
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
    }
    #[tokio::test]
    async fn pinned_origin_preserves_host_and_bounds_buffered_delivery() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            assert!(head(&mut socket).contains("unresolvable.invalid"));
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 65536\r\n\r\n")
                .unwrap();
            socket.write_all(&[7; 32768]).unwrap();
            socket.write_all(&[9; 32768]).unwrap();
        });
        let target =
            url::Url::parse(&format!("http://unresolvable.invalid:{}", address.port())).unwrap();
        let client = Client::create(&target, &[address], None).unwrap();
        let mut response = client.get(&target).send().await.unwrap();
        assert_eq!(
            response.chunk().await.unwrap().unwrap().as_ref(),
            &[7; 32768]
        );
        assert_eq!(
            response.chunk().await.unwrap().unwrap().as_ref(),
            &[9; 32768]
        );
        assert!(response.chunk().await.unwrap().is_none());
        server.join().unwrap();
        assert!(client.get("http://other.invalid").send().await.is_err());
    }
    #[test]
    fn missing_addresses_and_configured_proxies_are_rejected() {
        let target = url::Url::parse("https://example.com").unwrap();
        assert!(Client::create(&target, &[], None).is_err());
        for proxy in [
            "http://127.0.0.1:7890",
            "socks5://127.0.0.1:7890",
            "socks5h://127.0.0.1:7890",
        ] {
            let result = Client::create(
                &target,
                &["192.0.2.8:443".parse().unwrap()],
                Some(proxy.into()),
            );
            assert!(result.err().unwrap().contains("不支持代理"));
        }
    }
    #[tokio::test]
    async fn oversized_response_is_rejected_before_payload() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            head(&mut socket);
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                MAX_BODY + 1
            )
            .unwrap();
        });
        let target = url::Url::parse(&format!("http://{address}")).unwrap();
        let response = Client::create(&target, &[address], None)
            .unwrap()
            .get(&target)
            .send()
            .await;
        assert!(response.unwrap_err().to_string().contains("8 MiB"));
        server.join().unwrap();
    }
    #[tokio::test]
    async fn truncated_fixed_body_is_error_and_close_delimited_body_is_complete() {
        for (wire, valid) in [
            (
                b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc".as_slice(),
                false,
            ),
            (
                b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabc".as_slice(),
                true,
            ),
            (
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
                    .as_slice(),
                true,
            ),
        ] {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let server = std::thread::spawn(move || {
                let (mut socket, _) = listener.accept().unwrap();
                head(&mut socket);
                socket.write_all(wire).unwrap();
            });
            let target = url::Url::parse(&format!("http://{address}")).unwrap();
            let response = Client::create(&target, &[address], None)
                .unwrap()
                .get(&target)
                .send()
                .await;
            if valid {
                assert_eq!(
                    crate::net::read_limited(response.unwrap(), 1024)
                        .await
                        .unwrap(),
                    b"abc"
                );
            } else {
                assert!(response.is_err());
            }
            server.join().unwrap();
        }
    }
}
