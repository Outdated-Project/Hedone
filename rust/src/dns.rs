//! Bounded system DNS with a verified RecurseX DoH fallback.
//! This resolver never changes the HTTP target policy or the TLS hostname.
use courierust::courierust_tls::{system_roots, RootStore};
use nextjson::{NsonDeserialize, NsonSerialize};
use recurse_x::cache::persist::PersistConfig;
use recurse_x::forward::Forwarder;
use recurse_x::rdata::RData;
use recurse_x::upstream::{Endpoint, Proto};
use recurse_x::{Name, Rcode, Resolver, ResolverConfig, RrType};
use serde_json::{json, Value};
use std::io::Read;
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{OnceCell, Semaphore};

const SYSTEM_TIMEOUT: Duration = Duration::from_millis(1500);
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(7);
const CONFIG_LIMIT: u64 = 16 * 1024;
static STATE: OnceCell<Arc<Dns>> = OnceCell::const_new();
// A permit stays inside the blocking job even if the async caller is cancelled.
static WORKERS: Semaphore = Semaphore::const_new(8);
static SYSTEM_WORKERS: Semaphore = Semaphore::const_new(4);

#[derive(Debug, NsonSerialize, NsonDeserialize)]
#[njson(deny_unknown_fields)]
struct Settings {
    #[njson(default = "default_mode")]
    mode: String,
    #[njson(default = "default_upstreams")]
    upstreams: Vec<Upstream>,
}

#[derive(Debug, NsonSerialize, NsonDeserialize)]
#[njson(deny_unknown_fields)]
struct Upstream {
    ip: String,
    host: String,
}

fn default_mode() -> String {
    "auto".into()
}
fn default_upstreams() -> Vec<Upstream> {
    vec![
        Upstream {
            ip: "223.5.5.5".into(),
            host: "223.5.5.5".into(),
        },
        Upstream {
            ip: "1.1.1.1".into(),
            host: "1.1.1.1".into(),
        },
    ]
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            mode: default_mode(),
            upstreams: default_upstreams(),
        }
    }
}

struct Dns {
    settings: Settings,
    resolver: Resolver,
    last_save: Mutex<Instant>,
    system_answers: AtomicU64,
    encrypted_answers: AtomicU64,
    failures: AtomicU64,
}

fn load_settings(dir: Option<&Path>) -> Result<Settings, String> {
    let Some(path) = dir.map(|dir| dir.join("dns.json")) else {
        return Ok(Settings::default());
    };
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Settings::default()),
        Err(_) => return Err("无法读取 dns.json".into()),
    };
    let mut bytes = Vec::new();
    file.take(CONFIG_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "无法读取 dns.json")?;
    if bytes.len() as u64 > CONFIG_LIMIT {
        return Err("dns.json 超过 16 KiB".into());
    }
    nextjson::nextdecode(&bytes).map_err(|_| "dns.json 格式无效".into())
}

fn make_config(settings: &Settings, dir: Option<&Path>) -> Result<ResolverConfig, String> {
    if !matches!(settings.mode.as_str(), "auto" | "system" | "encrypted") {
        return Err("dns.json mode 只允许 auto、system、encrypted".into());
    }
    if settings.upstreams.is_empty() || settings.upstreams.len() > 4 {
        return Err("DNS 加密上游必须为 1–4 个".into());
    }
    let mut config = ResolverConfig::default();
    config.engine.query_budget_ms = 5000;
    config.engine.timeout_ms = 1800;
    config.engine.max_total_attempts = 4;
    config.engine.max_attempts_per_server = 1;
    config.cache.hot_capacity = 128;
    config.cache.warm_capacity = 512;
    config.cache.cold_capacity = 0;
    config.cache.nx_capacity = 256;
    config.cache.stale_window_secs = 0;
    config.max_inflight = 16;
    config.max_concurrent_refreshes = 0;
    config.max_prefetch_per_tick = 0;
    for upstream in &settings.upstreams {
        let ip: IpAddr = upstream.ip.parse().map_err(|_| "DNS 上游必须提供固定 IP")?;
        if !crate::network_policy::allowed_ip(ip)
            || matches!(ip, IpAddr::V4(v) if v.octets()[0] == 198 && matches!(v.octets()[1], 18 | 19))
        {
            return Err("DNS 上游必须使用真实公网 IP".into());
        }
        // This pinned DoH backend authenticates the URL's IP SAN.
        if upstream.host.parse::<IpAddr>().ok() != Some(ip) {
            return Err("此版本 DoH 的 TLS 身份必须与上游 IP 相同".into());
        }
        let forwarder = Forwarder::encrypted(
            Endpoint {
                ip,
                port: 443,
                proto: Proto::DoH,
            },
            upstream.host.clone(),
        );
        forwarder
            .validate()
            .map_err(|e| format!("DNS 上游配置无效：{e}"))?;
        config.engine.forwarders.push(forwarder);
    }
    // Courierust loads the OS store on supported hosts. Mobile sandbox hosts
    // without a readable store use the versioned Mozilla bundle, never verify=false.
    config.engine.forwarder_roots = system_roots::load()
        .or_else(|_| {
            let mut roots = RootStore::new();
            roots.add_pem(include_str!("../assets/cacert.pem"))?;
            Ok::<_, courierust::courierust_tls::TlsError>(roots)
        })
        .map_err(|_| "无法加载加密 DNS 的 CA 证书")?;
    if let Some(dir) = dir {
        let mut persist = PersistConfig::new(dir.join("dns-cache.rxc"), 0);
        persist.frame_limit = 2 * 1024 * 1024;
        config.persist = Some(persist);
    }
    Ok(config)
}

async fn state(dir: Option<PathBuf>) -> Result<&'static Arc<Dns>, String> {
    STATE
        .get_or_try_init(|| async move {
            tokio::task::spawn_blocking(move || {
                let settings = load_settings(dir.as_deref())?;
                let resolver = Resolver::new(make_config(&settings, dir.as_deref())?);
                Ok(Arc::new(Dns {
                    settings,
                    resolver,
                    last_save: Mutex::new(Instant::now()),
                    system_answers: AtomicU64::new(0),
                    encrypted_answers: AtomicU64::new(0),
                    failures: AtomicU64::new(0),
                }))
            })
            .await
            .map_err(|_| "DNS 初始化任务失败".to_string())?
        })
        .await
}

pub async fn initialize(dir: &Path) -> Result<(), String> {
    state(Some(dir.to_owned())).await.map(|_| ())
}

async fn encrypted(dns: Arc<Dns>, host: String, kind: RrType) -> Result<Vec<IpAddr>, String> {
    let permit = WORKERS.acquire().await.map_err(|_| "DNS 调度已关闭")?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let name = Name::from_ascii(&host).map_err(|_| "DNS 主机名无效")?;
        let result = dns
            .resolver
            .resolve(&name, kind)
            .map_err(|e| format!("RecurseX DNS 查询失败：{e}"))?;
        if result.rcode == Rcode::NXDOMAIN {
            return Err("DNS NXDOMAIN：域名不存在，请更换数据线路".into());
        }
        if result.rcode != Rcode::NOERROR {
            return Err(format!("DNS 返回 {:?}", result.rcode));
        }
        let addresses = result
            .answers
            .into_iter()
            .filter_map(|r| match r.rdata {
                RData::A(ip) => Some(IpAddr::V4(ip)),
                RData::Aaaa(ip) => Some(IpAddr::V6(ip)),
                _ => None,
            })
            .collect();
        // RecurseX writes its bounded snapshot through rustbinary/nextjson.
        // No timer or background polling wakes an idle media client.
        if let Ok(mut last) = dns.last_save.try_lock() {
            if last.elapsed() >= Duration::from_secs(60) {
                let _ = dns.resolver.persist_cache();
                *last = Instant::now();
            }
        }
        Ok(addresses)
    })
    .await
    .map_err(|_| "DNS 工作线程失败".to_string())?
}

async fn system(host: String, port: u16) -> Result<Vec<SocketAddr>, String> {
    let permit = SYSTEM_WORKERS
        .acquire()
        .await
        .map_err(|_| "DNS 调度已关闭")?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        (host.as_str(), port)
            .to_socket_addrs()
            .map(|addresses| addresses.collect())
            .map_err(|_| "系统 DNS 解析失败".to_string())
    })
    .await
    .map_err(|_| "系统 DNS 工作线程失败".to_string())?
}

pub async fn lookup(host: &str, port: u16) -> Result<Vec<SocketAddr>, String> {
    let dns = state(None).await?;
    if dns.settings.mode != "encrypted" {
        if let Ok(Ok(addresses)) =
            tokio::time::timeout(SYSTEM_TIMEOUT, system(host.to_owned(), port)).await
        {
            if !addresses.is_empty() {
                dns.system_answers.fetch_add(1, Ordering::Relaxed);
                return Ok(addresses);
            }
        }
        if dns.settings.mode == "system" {
            dns.failures.fetch_add(1, Ordering::Relaxed);
            return Err("系统 DNS 解析失败或超时".into());
        }
    }
    let result = tokio::time::timeout(LOOKUP_TIMEOUT, async {
        let (v4, v6) = tokio::join!(
            encrypted(dns.clone(), host.to_owned(), RrType::A),
            encrypted(dns.clone(), host.to_owned(), RrType::AAAA),
        );
        combine(v4, v6, port)
    })
    .await
    .map_err(|_| "RecurseX DNS 解析超时".to_string())
    .and_then(|r| r);
    if result.is_ok() {
        dns.encrypted_answers.fetch_add(1, Ordering::Relaxed);
    } else {
        dns.failures.fetch_add(1, Ordering::Relaxed);
    }
    result
}

fn combine(
    v4: Result<Vec<IpAddr>, String>,
    v6: Result<Vec<IpAddr>, String>,
    port: u16,
) -> Result<Vec<SocketAddr>, String> {
    let mut addresses = Vec::new();
    let mut error = "DNS 没有可用的 A/AAAA 记录".to_string();
    for result in [v6, v4] {
        match result {
            Ok(ips) => addresses.extend(ips.into_iter().map(|ip| SocketAddr::new(ip, port))),
            Err(e) => error = e,
        }
    }
    if addresses.is_empty() {
        Err(error)
    } else {
        Ok(addresses)
    }
}

pub fn diagnostics() -> Value {
    match STATE.get() {
        Some(dns) => json!({
            "engine": "RecurseX 0.2.4", "mode": dns.settings.mode,
            "transport": "DoH / Courierust 1.1.1", "certificate_verification": true,
            "system_answers": dns.system_answers.load(Ordering::Relaxed),
            "encrypted_answers": dns.encrypted_answers.load(Ordering::Relaxed),
            "failures": dns.failures.load(Ordering::Relaxed),
        }),
        None => json!({"engine": "RecurseX 0.2.4", "initialized": false}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nextjson_defaults_and_binary_contract_round_trip() {
        let settings: Settings = nextjson::nextdecode(b"{}").unwrap();
        assert_eq!(settings.mode, "auto");
        assert_eq!(settings.upstreams.len(), 2);
        let codec = rustbinary::options()
            .with_limit(CONFIG_LIMIT)
            .with_collection_limit(16);
        let bytes = codec.serialize(&settings).unwrap();
        let restored: Settings = codec.deserialize(&bytes).unwrap();
        assert_eq!(restored.upstreams[0].host, "223.5.5.5");
    }

    #[test]
    fn invalid_dns_settings_fail_closed() {
        let mut settings = Settings {
            mode: "insecure".into(),
            ..Settings::default()
        };
        assert!(make_config(&settings, None).is_err());
        settings.mode = "auto".into();
        settings.upstreams[0].ip = "127.0.0.1".into();
        assert!(make_config(&settings, None).is_err());
        settings.upstreams[0].ip = "198.18.0.1".into();
        assert!(make_config(&settings, None).is_err());
    }

    #[test]
    fn one_family_failure_preserves_the_other_family() {
        let ip: IpAddr = "2606:4700:4700::1111".parse().unwrap();
        assert_eq!(
            combine(Err("timeout".into()), Ok(vec![ip]), 443).unwrap(),
            vec![SocketAddr::new(ip, 443)]
        );
        assert!(combine(Ok(vec![]), Err("NXDOMAIN".into()), 443).is_err());
    }

    #[tokio::test]
    #[ignore = "requires public DNS over HTTPS"]
    async fn live_encrypted_dns() {
        let settings = Settings::default();
        let resolver = Resolver::new(make_config(&settings, None).unwrap());
        let dns = Arc::new(Dns {
            settings,
            resolver,
            last_save: Mutex::new(Instant::now()),
            system_answers: AtomicU64::new(0),
            encrypted_answers: AtomicU64::new(0),
            failures: AtomicU64::new(0),
        });
        let host = std::env::var("HGHUB_DNS_TEST_HOST").unwrap_or_else(|_| "example.com".into());
        let addresses = encrypted(dns, host, RrType::A).await.unwrap();
        assert!(!addresses.is_empty());
        assert!(addresses
            .iter()
            .all(|ip| crate::network_policy::allowed_ip(*ip)));
    }
}
