//! Origin-scoped asynchronous HTTP with bounded admission and verified Rustls TLS.
//! Redirect policy and DNS validation remain in net/network_policy.
pub use axum::http::header;
use axum::{
    body::Bytes,
    http::{HeaderMap, StatusCode},
};
use std::{io, net::SocketAddr, time::Duration};
use tokio::sync::{Semaphore, SemaphorePermit};
pub type Error = io::Error;
const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_TIMEOUT: Duration = Duration::from_secs(20);
static WORKERS: Semaphore = Semaphore::const_new(4);
static MEDIA_WORKERS: Semaphore = Semaphore::const_new(2);
fn error(e: impl std::fmt::Display) -> Error {
    io::Error::other(e.to_string())
}
fn request_error(e: reqwest::Error) -> Error {
    // Omit request URLs (including media tokens) while retaining the TLS cause.
    io::Error::other(e.without_url())
}

#[derive(Clone)]
pub struct Client {
    origin: url::Origin,
    inner: reqwest::Client,
}
impl Client {
    pub fn create(
        target: &url::Url,
        addresses: &[SocketAddr],
        proxy: Option<String>,
    ) -> Result<Self, String> {
        if !matches!(target.scheme(), "http" | "https")
            || !target.username().is_empty()
            || target.password().is_some()
        {
            return Err("HTTP 目标无效".into());
        }
        let port = target.port_or_known_default().ok_or("目标端口无效")?;
        if addresses.is_empty() || addresses.iter().any(|a| a.port() != port) {
            return Err("缺少有效的已校验 DNS 地址".into());
        }
        let host = target.host_str().ok_or("目标缺少主机名")?;
        let mut builder = reqwest::Client::builder()
            .use_rustls_tls()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .referer(false)
            .http1_only()
            .resolve_to_addrs(host, addresses)
            .user_agent(crate::net::UA)
            .connect_timeout(Duration::from_secs(8))
            .read_timeout(MAX_TIMEOUT)
            .pool_idle_timeout(Duration::from_secs(15))
            .pool_max_idle_per_host(2);
        if let Some(proxy) = proxy {
            // An explicitly configured system/application proxy is a trusted
            // network intermediary: CONNECT may resolve at that proxy. Never
            // fall back to direct access when the configured proxy fails.
            builder = builder.proxy(reqwest::Proxy::all(proxy).map_err(|_| "代理配置无效")?);
        }
        Ok(Self {
            origin: target.origin(),
            inner: builder.build().map_err(|e| e.to_string())?,
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
        self.request(url, reqwest::Method::GET)
    }
    pub fn post(&self, url: impl ToString) -> Request {
        self.request(url, reqwest::Method::POST)
    }
    fn request(&self, url: impl ToString, method: reqwest::Method) -> Request {
        let url = url.to_string();
        Request {
            origin: self.origin.clone(),
            inner: self.inner.request(method, &url),
            url,
            timeout: MAX_TIMEOUT,
        }
    }
}
pub struct Request {
    origin: url::Origin,
    inner: reqwest::RequestBuilder,
    url: String,
    timeout: Duration,
}
impl Request {
    pub fn header(mut self, name: impl ToString, value: impl ToString) -> Self {
        self.inner = self.inner.header(name.to_string(), value.to_string());
        self
    }
    pub fn body(mut self, body: String) -> Self {
        self.inner = self.inner.body(body);
        self
    }
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout.min(MAX_TIMEOUT);
        self
    }
    /// Header admission is bounded; body reads follow downstream demand. The
    /// separate media budget prevents long streams from starving catalogue calls.
    pub async fn send_streaming(self) -> Result<Response, Error> {
        let url = url::Url::parse(&self.url).map_err(error)?;
        if url.origin() != self.origin || !url.username().is_empty() || url.password().is_some() {
            return Err(error("拒绝未固定地址的请求来源"));
        }
        tokio::time::timeout(self.timeout, async move {
            let permit = MEDIA_WORKERS.acquire().await.map_err(error)?;
            let upstream = self
                .inner
                .header("accept-encoding", "identity")
                .send()
                .await
                .map_err(request_error)?;
            if upstream
                .headers()
                .get("content-encoding")
                .is_some_and(|v| v != "identity")
            {
                return Err(error("unsupported unsolicited content encoding"));
            }
            Ok(Response {
                status: upstream.status(),
                headers: upstream.headers().clone(),
                url,
                body: Bytes::new(),
                upstream: Some(upstream),
                permit: Some(permit),
            })
        })
        .await
        .map_err(|_| error("request timed out"))?
    }
    pub async fn send(self) -> Result<Response, Error> {
        let url = url::Url::parse(&self.url).map_err(error)?;
        if url.origin() != self.origin || !url.username().is_empty() || url.password().is_some() {
            return Err(error("拒绝未固定地址的请求来源"));
        }
        tokio::time::timeout(self.timeout, async move {
            let permit = WORKERS.acquire().await.map_err(error)?;
            let mut response = self
                .inner
                .header("accept-encoding", "identity")
                .timeout(self.timeout)
                .send()
                .await
                .map_err(request_error)?;
            if response
                .content_length()
                .is_some_and(|len| len > MAX_BODY as u64)
            {
                return Err(error("响应超过 8 MiB 上限"));
            }
            if response
                .headers()
                .get("content-encoding")
                .is_some_and(|v| v != "identity")
            {
                return Err(error("unsupported unsolicited content encoding"));
            }
            let status = response.status();
            let headers = response.headers().clone();
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(request_error)? {
                if chunk.len() > MAX_BODY - body.len() {
                    return Err(error("响应超过 8 MiB 上限"));
                }
                body.extend_from_slice(&chunk);
            }
            Ok(Response {
                status,
                headers,
                url,
                body: Bytes::from(body),
                upstream: None,
                permit: Some(permit),
            })
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
    upstream: Option<reqwest::Response>,
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
    pub async fn chunk(&mut self) -> Result<Option<Bytes>, Error> {
        while self.body.is_empty() {
            let Some(upstream) = &mut self.upstream else {
                self.permit.take();
                return Ok(None);
            };
            match upstream.chunk().await {
                Ok(Some(bytes)) => self.body = bytes,
                Ok(None) => {
                    self.upstream.take();
                }
                Err(e) => {
                    self.upstream.take();
                    self.permit.take();
                    return Err(request_error(e));
                }
            }
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
    use std::sync::Arc;
    #[test]
    fn cross_signed_chain_uses_valid_anchor_and_rejects_invalid_certificates() {
        use rustls::{
            client::danger::ServerCertVerifier,
            pki_types::{CertificateDer, ServerName, UnixTime},
        };
        let roots = rustls::RootCertStore {
            roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
        };
        let verifier = rustls::client::WebPkiServerVerifier::builder_with_provider(
            Arc::new(roots),
            Arc::new(rustls::crypto::ring::default_provider()),
        )
        .build()
        .unwrap();
        let leaf = CertificateDer::from(
            include_bytes!("../tests/fixtures/cross_signed/leaf.der").to_vec(),
        );
        let intermediates = [
            CertificateDer::from(
                include_bytes!("../tests/fixtures/cross_signed/intermediate.der").to_vec(),
            ),
            CertificateDer::from(
                include_bytes!("../tests/fixtures/cross_signed/cross-signed-root.der").to_vec(),
            ),
        ];
        let name = ServerName::try_from("huangguoai.ai").unwrap();
        let now = UnixTime::since_unix_epoch(Duration::from_secs(1_794_355_200));
        verifier
            .verify_server_cert(&leaf, &intermediates, &name, &[], now)
            .unwrap();
        let wrong = ServerName::try_from("wrong.example").unwrap();
        assert!(
            verifier
                .verify_server_cert(&leaf, &intermediates, &wrong, &[], now)
                .is_err()
        );
        let expired = UnixTime::since_unix_epoch(Duration::from_secs(1_794_355_200 + 365 * 86400));
        assert!(
            verifier
                .verify_server_cert(&leaf, &intermediates, &name, &[], expired)
                .is_err()
        );
        let mut damaged = leaf.to_vec();
        *damaged.last_mut().unwrap() ^= 1;
        assert!(
            verifier
                .verify_server_cert(
                    &CertificateDer::from(damaged),
                    &intermediates,
                    &name,
                    &[],
                    now
                )
                .is_err()
        );
        assert!(
            verifier
                .verify_server_cert(&leaf, &[], &name, &[], now)
                .is_err()
        );
    }
    #[tokio::test]
    #[ignore = "live direct HTTPS requests with normal certificate verification"]
    async fn live_bundled_roots_validate_primary_origin() {
        let mut failures = Vec::new();
        for origin in [
            crate::net::DEFAULT_BASE,
            "https://huangguoai.ai",
            "https://huangguoai.pages.dev",
        ] {
            let target = url::Url::parse(origin).unwrap();
            let addresses = crate::dns::lookup(target.host_str().unwrap(), 443)
                .await
                .unwrap();
            let client = Client::create(&target, &addresses, None).unwrap();
            match client.get(&target).send().await {
                Ok(response) => println!("{origin}: HTTP {} (verified TLS)", response.status()),
                Err(error) => failures.push(format!("{origin}: {error}")),
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
    #[tokio::test]
    #[ignore = "live upstream playback API; set HEDONE_TEST_VIDEO_ID"]
    async fn live_manifest_can_reopen_same_origin() {
        let id = std::env::var("HEDONE_TEST_VIDEO_ID")
            .unwrap()
            .parse()
            .unwrap();
        let api = crate::api::Api::new();
        let play = crate::api::api_play(&api, id, 1).await.unwrap();
        let url = play["video_url"].as_str().unwrap();
        for _ in 0..3 {
            let response = crate::net::get_media_stream(
                url,
                &format!("{}/", crate::net::base()),
                Some("bytes=0-"),
            )
            .await
            .unwrap();
            let bytes = crate::net::read_limited(response, 2 * 1024 * 1024)
                .await
                .unwrap();
            assert!(bytes.starts_with(b"#EXTM3U"));
        }
    }
    #[tokio::test]
    async fn media_headers_arrive_before_body_and_large_payload_stays_chunked() {
        const LENGTH: usize = 24 * 1024 * 1024 + 7;
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (ready, proceed) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            assert!(head(&mut socket).to_lowercase().contains("range: bytes=0-"));
            // No ETag: one response does not need version-checked stitching.
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: {LENGTH}\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
            proceed.recv_timeout(Duration::from_secs(5)).unwrap();
            let block = [0x5au8; 16384];
            let mut remaining = LENGTH;
            while remaining > 0 {
                let size = remaining.min(block.len());
                socket.write_all(&block[..size]).unwrap();
                remaining -= size;
            }
        });
        let target = url::Url::parse(&format!("http://{address}/large.ts")).unwrap();
        let client = Client::create(&target, &[address], None).unwrap();
        let mut response = client
            .get(&target)
            .header("Range", "bytes=0-")
            .send_streaming()
            .await
            .unwrap();
        assert_eq!(response.content_length(), Some(LENGTH as u64));
        assert!(response.body.is_empty());
        ready.send(()).unwrap();
        let mut delivered = 0;
        while let Some(chunk) = response.chunk().await.unwrap() {
            assert!(chunk.len() <= 32768);
            assert!(chunk.iter().all(|b| *b == 0x5a));
            delivered += chunk.len();
        }
        assert_eq!(delivered, LENGTH);
        assert!(response.permit.is_none());
        server.join().unwrap();
    }
    #[tokio::test]
    async fn cancelled_media_releases_admission_and_truncation_reports_error() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for _ in 0..3 {
                let (mut socket, _) = listener.accept().unwrap();
                head(&mut socket);
                socket
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nabc",
                    )
                    .unwrap();
            }
        });
        let target = url::Url::parse(&format!("http://{address}/clip")).unwrap();
        let client = Client::create(&target, &[address], None).unwrap();
        for _ in 0..2 {
            drop(client.get(&target).send_streaming().await.unwrap());
        }
        let response = client.get(&target).send_streaming().await.unwrap();
        assert!(crate::net::read_limited(response, 100).await.is_err());
        server.join().unwrap();
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
    fn missing_addresses_are_rejected_and_configured_proxies_are_supported() {
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
            assert!(result.is_ok());
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
