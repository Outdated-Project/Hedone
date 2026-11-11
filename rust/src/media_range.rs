//! Progressive media delivery via bounded, version-checked HTTP Range requests.
//! Each individual upstream response is still buffered by official Courierust.
use crate::transport;
use axum::{
    body::Bytes,
    http::{HeaderMap, StatusCode},
};
use futures_util::{Stream, stream};
use std::{future::Future, io, pin::Pin};

pub(crate) const WINDOW: u64 = 1024 * 1024;
type ByteStream = Pin<Box<dyn Stream<Item = Result<Bytes, io::Error>> + Send>>;

pub(crate) struct Download {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub url: url::Url,
    pub body: ByteStream,
}

#[derive(Clone, Copy, Debug)]
enum Requested {
    Full,
    From { start: u64, end: Option<u64> },
    Suffix(u64),
}
impl Requested {
    fn parse(raw: Option<&str>) -> Result<Self, String> {
        let Some(raw) = raw else {
            return Ok(Self::Full);
        };
        if raw.len() > 100 {
            return Err("无效媒体 Range".into());
        }
        let (start, end) = raw
            .strip_prefix("bytes=")
            .and_then(|s| s.split_once('-'))
            .ok_or("无效媒体 Range")?;
        if start.is_empty() {
            let suffix = decimal(end)?;
            return if suffix == 0 {
                Err("无效媒体 Range".into())
            } else {
                Ok(Self::Suffix(suffix))
            };
        }
        let start = decimal(start)?;
        let end = if end.is_empty() {
            None
        } else {
            Some(decimal(end)?)
        };
        if end.is_some_and(|end| end < start) {
            return Err("无效媒体 Range".into());
        }
        Ok(Self::From { start, end })
    }
    fn probe(self) -> String {
        match self {
            Self::Full => window(0, u64::MAX),
            Self::From { start, end } => window(start, end.unwrap_or(u64::MAX)),
            Self::Suffix(length) => format!("bytes=-{}", length.min(WINDOW)),
        }
    }
    fn bounds(self, total: u64) -> Result<(u64, u64), String> {
        if total == 0 {
            return Err("无效媒体长度".into());
        }
        match self {
            Self::Full => Ok((0, total - 1)),
            Self::From { start, end } if start < total => {
                Ok((start, end.unwrap_or(total - 1).min(total - 1)))
            }
            Self::Suffix(length) => Ok((total.saturating_sub(length), total - 1)),
            _ => Err("媒体 Range 超出资源长度".into()),
        }
    }
}
fn decimal(text: &str) -> Result<u64, String> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err("无效媒体 Range 数字".into());
    }
    text.parse().map_err(|_| "媒体 Range 数字溢出".into())
}
pub(crate) fn valid_range(raw: &str) -> bool {
    Requested::parse(Some(raw)).is_ok()
}
fn window(start: u64, end: u64) -> String {
    format!(
        "bytes={start}-{}",
        end.min(start.saturating_add(WINDOW - 1))
    )
}
#[derive(Debug)]
struct Span {
    start: u64,
    end: u64,
    total: u64,
}
fn span(response: &transport::Response) -> Result<Span, String> {
    if response.headers().get_all("content-range").iter().count() != 1 {
        return Err("媒体响应需要唯一的 Content-Range".into());
    }
    let value = response
        .headers()
        .get("content-range")
        .and_then(|v| v.to_str().ok())
        .ok_or("媒体响应缺少 Content-Range")?;
    let (bounds, total) = value
        .strip_prefix("bytes ")
        .and_then(|s| s.split_once('/'))
        .ok_or("无效媒体 Content-Range")?;
    let (start, end) = bounds.split_once('-').ok_or("无效媒体 Content-Range")?;
    let span = Span {
        start: decimal(start)?,
        end: decimal(end)?,
        total: decimal(total)?,
    };
    if span.start > span.end
        || span.end >= span.total
        || span.end - span.start + 1 > WINDOW
        || response.buffered_len() as u64 != span.end - span.start + 1
    {
        return Err("媒体响应范围或长度与请求不一致".into());
    }
    Ok(span)
}
fn strong_etag(headers: &HeaderMap) -> Option<String> {
    if headers.get_all("etag").iter().count() != 1 {
        return None;
    }
    let value = headers.get("etag")?.to_str().ok()?;
    let inner = value.strip_prefix('"')?.strip_suffix('"')?;
    inner
        .bytes()
        .all(|b| b == 0x21 || (0x23..=0x7e).contains(&b))
        .then(|| value.to_owned())
}

struct Transfer<F> {
    fetch: F,
    current: Option<transport::Response>,
    next: u64,
    end: u64,
    total: u64,
    etag: Option<String>,
    url: url::Url,
}

/// The fetch closure supplies application redirect/DNS policy. Tests exercise
/// the same algorithm with real Courierust requests to a local HTTP server.
pub(crate) async fn open<F, Fut>(
    source: &url::Url,
    raw_range: Option<&str>,
    mut fetch: F,
) -> Result<Download, String>
where
    F: FnMut(url::Url, String, Option<String>) -> Fut + Send + 'static,
    Fut: Future<Output = Result<transport::Response, String>> + Send,
{
    let requested = Requested::parse(raw_range)?;
    let first = fetch(source.clone(), requested.probe(), None).await?;
    let mut headers = first.headers().clone();
    let url = first.url().clone();
    if first.status() != StatusCode::PARTIAL_CONTENT {
        // Servers may ignore Range. Courierust's normal 8 MiB cap still applies.
        return Ok(Download {
            status: first.status(),
            headers,
            url,
            body: Box::pin(first.bytes_stream()),
        });
    }
    let first_span = span(&first)?;
    let (start, end) = requested.bounds(first_span.total)?;
    let probe_start = match requested {
        Requested::Suffix(length) => first_span.total.saturating_sub(length.min(WINDOW)),
        _ => start,
    };
    let probe_end = end.min(probe_start.saturating_add(WINDOW - 1));
    if first_span.start != probe_start || first_span.end != probe_end {
        return Err("上游没有返回请求的媒体范围".into());
    }
    let etag = strong_etag(&headers);
    let continuing = first_span.start != start || first_span.end < end;
    if continuing && etag.is_none() {
        return Err(
            "当前 Courierust 分段播放需要上游支持 Range 和强 ETag，无法安全拼接此资源".into(),
        );
    }
    let next = if first_span.start == start {
        first_span.end + 1
    } else {
        start
    };
    let current = if first_span.start == start {
        Some(first)
    } else {
        None
    };
    let status = if matches!(requested, Requested::Full) {
        StatusCode::OK
    } else {
        StatusCode::PARTIAL_CONTENT
    };
    headers.remove("transfer-encoding");
    headers.remove("content-range");
    headers.insert(
        "content-length",
        (end - start + 1)
            .to_string()
            .parse()
            .map_err(|_| "无效媒体长度")?,
    );
    headers.insert("accept-ranges", "bytes".parse().unwrap());
    if status == StatusCode::PARTIAL_CONTENT {
        headers.insert(
            "content-range",
            format!("bytes {start}-{end}/{}", first_span.total)
                .parse()
                .map_err(|_| "无效媒体范围")?,
        );
    }
    let transfer = Transfer {
        fetch,
        current,
        next,
        end,
        total: first_span.total,
        etag,
        url: url.clone(),
    };
    let body = stream::try_unfold(transfer, |mut transfer| async move {
        loop {
            if let Some(response) = &mut transfer.current {
                if let Some(bytes) = response.chunk().await? {
                    return Ok(Some((bytes, transfer)));
                }
                transfer.current = None;
            }
            if transfer.next > transfer.end {
                return Ok(None);
            }
            let response = (transfer.fetch)(
                transfer.url.clone(),
                window(transfer.next, transfer.end),
                transfer.etag.clone(),
            )
            .await
            .map_err(io::Error::other)?;
            if response.status() != StatusCode::PARTIAL_CONTENT
                || response.url() != &transfer.url
                || strong_etag(response.headers()) != transfer.etag
            {
                return Err(io::Error::other("媒体资源已变化或上游不再支持条件 Range"));
            }
            let part = span(&response).map_err(io::Error::other)?;
            if part.total != transfer.total
                || part.start != transfer.next
                || part.end != transfer.end.min(transfer.next.saturating_add(WINDOW - 1))
            {
                return Err(io::Error::other("媒体续传范围不一致，已停止拼接"));
            }
            transfer.next = part.end + 1;
            transfer.current = Some(response);
        }
    });
    Ok(Download {
        status,
        headers,
        url,
        body: Box::pin(body),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{StreamExt, future::BoxFuture};
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        time::{Duration, Instant},
    };

    struct Reply {
        range: String,
        start: u64,
        end: u64,
        total: u64,
        etag: Option<&'static str>,
        status: u16,
    }
    impl Reply {
        fn part(start: u64, end: u64, total: u64) -> Self {
            Self {
                range: format!("bytes={start}-{end}"),
                start,
                end,
                total,
                etag: Some("\"v1\""),
                status: 206,
            }
        }
    }
    type Fetch = Box<
        dyn FnMut(
                url::Url,
                String,
                Option<String>,
            ) -> BoxFuture<'static, Result<transport::Response, String>>
            + Send,
    >;
    struct Fixture {
        client: transport::Client,
        target: url::Url,
        count: Arc<AtomicUsize>,
        server: std::thread::JoinHandle<()>,
    }
    impl Fixture {
        fn new(replies: Vec<Reply>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            listener.set_nonblocking(true).unwrap();
            let count = Arc::new(AtomicUsize::new(0));
            let counter = count.clone();
            let server = std::thread::spawn(move || {
                for (index, reply) in replies.into_iter().enumerate() {
                    let deadline = Instant::now() + Duration::from_secs(10);
                    let mut socket = loop {
                        match listener.accept() {
                            Ok((socket, _)) => break socket,
                            Err(e)
                                if e.kind() == io::ErrorKind::WouldBlock
                                    && Instant::now() < deadline =>
                            {
                                std::thread::sleep(Duration::from_millis(5))
                            }
                            Err(e) => panic!("expected Range request: {e}"),
                        }
                    };
                    socket.set_nonblocking(false).unwrap();
                    socket
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    socket
                        .set_write_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    let mut head = Vec::new();
                    while !head.ends_with(b"\r\n\r\n") {
                        let mut byte = [0];
                        socket.read_exact(&mut byte).unwrap();
                        head.push(byte[0]);
                        assert!(head.len() < 8192);
                    }
                    let head = String::from_utf8(head).unwrap().to_ascii_lowercase();
                    assert!(head.contains(&format!("\r\nrange: {}\r\n", reply.range)));
                    assert_eq!(head.contains("\r\nif-match: \"v1\"\r\n"), index > 0);
                    counter.fetch_add(1, Ordering::SeqCst);
                    write!(socket, "HTTP/1.1 {} OK\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\nConnection: close\r\n", reply.status, reply.end - reply.start + 1).unwrap();
                    if reply.status == 206 {
                        write!(
                            socket,
                            "Content-Range: bytes {}-{}/{}\r\n",
                            reply.start, reply.end, reply.total
                        )
                        .unwrap();
                    }
                    if let Some(etag) = reply.etag {
                        write!(socket, "ETag: {etag}\r\n").unwrap();
                    }
                    socket.write_all(b"\r\n").unwrap();
                    let body: Vec<u8> =
                        (reply.start..=reply.end).map(|i| (i % 251) as u8).collect();
                    socket.write_all(&body).unwrap();
                }
            });
            let target = url::Url::parse(&format!("http://{address}/video.mp4")).unwrap();
            Self {
                client: transport::Client::create(&target, &[address], None).unwrap(),
                target,
                count,
                server,
            }
        }
        fn fetcher(&self) -> Fetch {
            let client = self.client.clone();
            Box::new(move |target, range, etag| {
                let client = client.clone();
                Box::pin(async move {
                    let mut request = client
                        .get(target)
                        .header("Range", range)
                        .timeout(Duration::from_secs(5));
                    if let Some(etag) = etag {
                        request = request.header("If-Match", etag);
                    }
                    request.send().await.map_err(|e| e.to_string())
                })
            })
        }
        fn finish(self) {
            self.server.join().unwrap();
        }
    }
    async fn check_bytes(mut download: Download, start: u64, end: u64) {
        let mut offset = start;
        while let Some(chunk) = download.body.next().await {
            let chunk = chunk.unwrap();
            assert!(chunk.len() <= 32768);
            for &byte in &chunk {
                assert_eq!(byte, (offset % 251) as u8);
                offset += 1;
            }
        }
        assert_eq!(offset, end + 1);
    }
    #[tokio::test]
    async fn large_media_is_delivered_lazily_without_an_eight_mib_file_limit() {
        let total = 9 * WINDOW + 19;
        let replies = (0..total)
            .step_by(WINDOW as usize)
            .map(|start| Reply::part(start, (start + WINDOW - 1).min(total - 1), total))
            .collect();
        let fixture = Fixture::new(replies);
        let download = open(&fixture.target, None, fixture.fetcher())
            .await
            .unwrap();
        assert_eq!(fixture.count.load(Ordering::SeqCst), 1);
        assert_eq!(download.status, StatusCode::OK);
        assert_eq!(download.headers["content-length"], total.to_string());
        assert!(!download.headers.contains_key("content-range"));
        check_bytes(download, 0, total - 1).await;
        assert_eq!(fixture.count.load(Ordering::SeqCst), 10);
        fixture.finish();
    }
    #[tokio::test]
    async fn seek_and_long_suffix_preserve_exact_ranges() {
        let total = 3 * WINDOW;
        let start = 37;
        let end = start + WINDOW + 9;
        let fixture = Fixture::new(vec![
            Reply::part(start, start + WINDOW - 1, total),
            Reply::part(start + WINDOW, end, total),
        ]);
        let download = open(
            &fixture.target,
            Some(&format!("bytes={start}-{end}")),
            fixture.fetcher(),
        )
        .await
        .unwrap();
        assert_eq!(
            download.headers["content-range"],
            format!("bytes {start}-{end}/{total}")
        );
        check_bytes(download, start, end).await;
        fixture.finish();
        let start = total - WINDOW - 7;
        let mut probe = Reply::part(total - WINDOW, total - 1, total);
        probe.range = format!("bytes=-{WINDOW}");
        let fixture = Fixture::new(vec![
            probe,
            Reply::part(start, start + WINDOW - 1, total),
            Reply::part(start + WINDOW, total - 1, total),
        ]);
        let download = open(
            &fixture.target,
            Some(&format!("bytes=-{}", WINDOW + 7)),
            fixture.fetcher(),
        )
        .await
        .unwrap();
        check_bytes(download, start, total - 1).await;
        fixture.finish();
    }
    #[tokio::test]
    async fn changed_etag_stops_before_changed_bytes_reach_player() {
        let total = WINDOW + 10;
        let mut second = Reply::part(WINDOW, total - 1, total);
        second.etag = Some("\"v2\"");
        let fixture = Fixture::new(vec![Reply::part(0, WINDOW - 1, total), second]);
        let mut download = open(&fixture.target, None, fixture.fetcher())
            .await
            .unwrap();
        let mut consumed = 0;
        loop {
            match download.body.next().await.unwrap() {
                Ok(bytes) => consumed += bytes.len(),
                Err(error) => {
                    assert!(error.to_string().contains("已变化"));
                    break;
                }
            }
        }
        assert_eq!(consumed as u64, WINDOW);
        fixture.finish();
    }
    #[tokio::test]
    async fn weak_validators_and_wrong_ranges_are_rejected() {
        let mut weak = Reply::part(0, WINDOW - 1, 2 * WINDOW);
        weak.etag = Some("W/\"v1\"");
        let fixture = Fixture::new(vec![weak]);
        assert!(
            open(&fixture.target, None, fixture.fetcher())
                .await
                .err()
                .unwrap()
                .contains("强 ETag")
        );
        fixture.finish();
        let mut wrong = Reply::part(1, WINDOW, 2 * WINDOW);
        wrong.range = window(0, u64::MAX);
        let fixture = Fixture::new(vec![wrong]);
        assert!(
            open(&fixture.target, None, fixture.fetcher())
                .await
                .err()
                .unwrap()
                .contains("请求的媒体范围")
        );
        fixture.finish();
    }
    #[tokio::test]
    async fn ignoring_range_keeps_small_response_and_drop_does_not_prefetch() {
        let mut small = Reply::part(0, 9, 10);
        small.range = window(0, u64::MAX);
        small.status = 200;
        small.etag = None;
        let fixture = Fixture::new(vec![small]);
        check_bytes(
            open(&fixture.target, None, fixture.fetcher())
                .await
                .unwrap(),
            0,
            9,
        )
        .await;
        fixture.finish();
        let fixture = Fixture::new(vec![Reply::part(0, WINDOW - 1, 9 * WINDOW)]);
        let mut download = open(&fixture.target, None, fixture.fetcher())
            .await
            .unwrap();
        assert_eq!(download.body.next().await.unwrap().unwrap().len(), 32768);
        drop(download);
        assert_eq!(fixture.count.load(Ordering::SeqCst), 1);
        fixture.finish();
    }
    #[test]
    fn range_arithmetic_handles_suffix_clipping_and_overflow() {
        assert_eq!(
            Requested::parse(Some("bytes=-20"))
                .unwrap()
                .bounds(10)
                .unwrap(),
            (0, 9)
        );
        assert_eq!(
            Requested::parse(Some("bytes=3-99"))
                .unwrap()
                .bounds(10)
                .unwrap(),
            (3, 9)
        );
        assert!(
            Requested::parse(Some("bytes=10-"))
                .unwrap()
                .bounds(10)
                .is_err()
        );
        for raw in [
            "bytes=-0",
            "bytes=9-1",
            "bytes=0-1,3-4",
            "bytes=+1-2",
            "bytes=18446744073709551616-",
        ] {
            assert!(Requested::parse(Some(raw)).is_err(), "{raw}");
        }
        assert_eq!(
            window(u64::MAX - 1, u64::MAX),
            format!("bytes={}-{}", u64::MAX - 1, u64::MAX)
        );
    }
}
