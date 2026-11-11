use courierust::courierust_tls::{RootStore, system_roots};
use nextjson::{NsonDeserialize, NsonSerialize};
use nextjson::{Value, json};
use recurse_x::cache::persist::PersistConfig;
use recurse_x::forward::Forwarder;
use recurse_x::rdata::RData;
use recurse_x::upstream::{Endpoint, Proto};
use recurse_x::{Name, Rcode, Resolver, ResolverConfig, RrType};
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
const ENGINE: &str = "RecurseX 0.2.6";
static STATE: OnceCell<Arc<Dns>> = OnceCell::const_new();
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
        Err(_) => return Err("Failed to read dns.json".into()),
    };
    let mut bytes = Vec::new();
    file.take(CONFIG_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Failed to read dns.json")?;
    if bytes.len() as u64 > CONFIG_LIMIT {
        return Err("dns.json is over 16 KiB".into());
    }
    nextjson::nextdecode(&bytes).map_err(|_| "dns.json format is invalid".into())
}

fn make_config(settings: &Settings, dir: Option<&Path>) -> Result<ResolverConfig, String> {
    if !matches!(settings.mode.as_str(), "auto" | "system" | "encrypted") {
        return Err("The `dns.json` mode only allows `auto`, `system`, or `encrypted`".into());
    }
    if settings.upstreams.is_empty() || settings.upstreams.len() > 4 {
        return Err("There must be 1–4 encrypted DNS upstream servers".into());
    }
    let mut config = ResolverConfig::default();
    config.dns.privacy.encrypted_only = true;
    config.dns.privacy.parallel = false;
    config.dns.privacy.max_upstreams = settings.upstreams.len();
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
        let ip: IpAddr = upstream
            .ip
            .parse()
            .map_err(|_| "Encrypted DNS upstream must provide a fixed IP")?;
        if !crate::network_policy::allowed_ip(ip)
            || matches!(ip, IpAddr::V4(v) if v.octets()[0] == 198 && matches!(v.octets()[1], 18 | 19))
        {
            return Err("The DNS upstream must use a real public IP address".into());
        }
        // This pinned DoH backend authenticates the URL's IP SAN.
        if upstream.host.parse::<IpAddr>().ok() != Some(ip) {
            return Err(
                "For this version of DoH, the TLS identity must match the upstream IP".into(),
            );
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
            .map_err(|e| format!("Invalid DNS upstream configuration: {e}"))?;
        config.engine.forwarders.push(forwarder);
    }
    config.engine.forwarder_roots = match system_roots::load() {
        Ok(roots) if !roots.is_empty() => roots,
        _ => {
            let mut roots = RootStore::new();
            roots
                .add_pem(include_str!("../assets/cacert.pem"))
                .map_err(|_| "Failed to load the CA certificate for encrypted DNS")?;
            roots
        }
    };
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
            .map_err(|_| "DNS initialization task failed".to_string())?
        })
        .await
}

pub async fn initialize(dir: &Path) -> Result<(), String> {
    state(Some(dir.to_owned())).await.map(|_| ())
}

async fn encrypted(dns: Arc<Dns>, host: String, kind: RrType) -> Result<Vec<IpAddr>, String> {
    let permit = WORKERS
        .acquire()
        .await
        .map_err(|_| "Encrypted DNS scheduling is closed")?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let name = Name::from_ascii(&host).map_err(|_| "Invalid DNS host name")?;
        let result = dns
            .resolver
            .resolve(&name, kind)
            .map_err(|e| format!("RecurseX DNS query failed: {e}"))?;
        if result.rcode == Rcode::NXDOMAIN {
            return Err("DNS NXDOMAIN: Domain does not exist, please change the data line".into());
        }
        if result.rcode != Rcode::NOERROR {
            return Err(format!("DNS returns {:?}", result.rcode));
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
        if let Ok(mut last) = dns.last_save.try_lock()
            && last.elapsed() >= Duration::from_secs(60)
        {
            let _ = dns.resolver.persist_cache();
            *last = Instant::now();
        }
        Ok(addresses)
    })
    .await
    .map_err(|_| "Encrypted DNS worker thread failed".to_string())?
}

async fn system(host: String, port: u16) -> Result<Vec<SocketAddr>, String> {
    let permit = SYSTEM_WORKERS
        .acquire()
        .await
        .map_err(|_| "System DNS scheduling closed")?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        (host.as_str(), port)
            .to_socket_addrs()
            .map(|addresses| addresses.collect())
            .map_err(|_| "System DNS resolution failed".to_string())
    })
    .await
    .map_err(|_| "System DNS worker thread failed".to_string())?
}

pub async fn lookup(host: &str, port: u16) -> Result<Vec<SocketAddr>, String> {
    let dns = state(None).await?;
    let mut system_fallback = None;
    if dns.settings.mode != "encrypted" {
        if let Ok(Ok(addresses)) =
            tokio::time::timeout(SYSTEM_TIMEOUT, system(host.to_owned(), port)).await
            && use_system_answer(&dns.settings.mode, &addresses)
        {
            // Preserve a VPN's validated FakeIP mapping. Ordinary public
            // answers may still be poisoned, so prefer authenticated DoH.
            if dns.settings.mode == "system" || contains_fake_ip(&addresses) {
                dns.system_answers.fetch_add(1, Ordering::Relaxed);
                return Ok(addresses);
            }
            system_fallback = Some(addresses);
        }
        if dns.settings.mode == "system" {
            dns.failures.fetch_add(1, Ordering::Relaxed);
            return Err("System DNS resolution failed or timed out".into());
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
    .map_err(|_| "RecurseX DNS resolution timeout".to_string())
    .and_then(|r| r);
    if result.is_ok() {
        dns.encrypted_answers.fetch_add(1, Ordering::Relaxed);
    } else if let Some(addresses) = system_fallback {
        dns.system_answers.fetch_add(1, Ordering::Relaxed);
        return Ok(addresses);
    } else {
        dns.failures.fetch_add(1, Ordering::Relaxed);
    }
    result
}

fn contains_fake_ip(addresses: &[SocketAddr]) -> bool {
    addresses.iter().any(|address| {
        let v4 = match address.ip() {
            IpAddr::V4(ip) => Some(ip),
            IpAddr::V6(ip) => ip.to_ipv4_mapped(),
        };
        v4.is_some_and(|ip| ip.octets()[0] == 198 && matches!(ip.octets()[1], 18 | 19))
    })
}

fn use_system_answer(mode: &str, addresses: &[SocketAddr]) -> bool {
    !addresses.is_empty()
        && (mode == "system"
            || addresses
                .iter()
                .all(|address| crate::network_policy::allowed_ip(address.ip())))
}

fn combine(
    v4: Result<Vec<IpAddr>, String>,
    v6: Result<Vec<IpAddr>, String>,
    port: u16,
) -> Result<Vec<SocketAddr>, String> {
    let mut addresses = Vec::new();
    let mut error = "DNS has no available A/AAAA records".to_string();
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
            "engine": ENGINE, "mode": dns.settings.mode,
            "transport": "DoH / Courierust 1.1.2", "certificate_verification": true,
            "dnssec_validation": false,
            "system_answers": dns.system_answers.load(Ordering::Relaxed),
            "encrypted_answers": dns.encrypted_answers.load(Ordering::Relaxed),
            "failures": dns.failures.load(Ordering::Relaxed),
        }),
        None => json!({"engine": ENGINE, "initialized": false}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_retries_restricted_system_answers_without_weakening_system_mode() {
        let public: SocketAddr = "1.1.1.1:443".parse().unwrap();
        let blocked: SocketAddr = "0.0.0.0:443".parse().unwrap();
        assert!(use_system_answer("auto", &[public]));
        assert!(!contains_fake_ip(&[public]));
        assert!(contains_fake_ip(&["198.18.0.1:443".parse().unwrap()]));
        assert!(contains_fake_ip(&["[::ffff:198.19.0.1]:443"
            .parse()
            .unwrap()]));
        assert!(!contains_fake_ip(&["[::ffff:1.1.1.1]:443"
            .parse()
            .unwrap()]));
        assert!(use_system_answer(
            "auto",
            &["198.18.0.1:443".parse().unwrap()]
        ));
        assert!(!use_system_answer("auto", &[]));
        for denied in [
            blocked,
            "127.0.0.1:443".parse().unwrap(),
            "[::1]:443".parse().unwrap(),
        ] {
            assert!(!use_system_answer("auto", &[denied]));
            assert!(!use_system_answer("auto", &[public, denied]));
            assert!(use_system_answer("system", &[public, denied]));
            assert!(
                crate::network_policy::check_addresses_with_mode(&[public, denied], true).is_err()
            );
        }
    }

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

    #[test]
    fn encrypted_config_bounds_work_and_forbids_plaintext_fallback() {
        let config = make_config(&Settings::default(), Some(Path::new("dns-test"))).unwrap();
        assert!(config.dns.privacy.encrypted_only);
        assert!(!config.dns.privacy.parallel);
        assert_eq!(config.dns.privacy.max_upstreams, 2);
        assert_eq!(config.engine.forwarders.len(), 2);
        assert!(!config.engine.forwarder_roots.is_empty());
        assert!(
            config
                .engine
                .forwarders
                .iter()
                .all(|f| f.endpoint.proto == Proto::DoH)
        );
        assert_eq!(config.max_concurrent_refreshes, 0);
        assert_eq!(config.cache.stale_window_secs, 0);
        assert!(config.engine.query_budget_ms < LOOKUP_TIMEOUT.as_millis() as u64);
        let persist = config.persist.unwrap();
        assert_eq!(persist.save_interval_ms, 0);
        assert_eq!(persist.frame_limit, 2 * 1024 * 1024);
    }

    #[test]
    fn encrypted_upstreams_reject_identity_mismatch_and_unbounded_lists() {
        let mut settings = Settings::default();
        settings.upstreams[0].host = "dns.alidns.com".into();
        assert!(make_config(&settings, None).is_err());
        settings.upstreams.clear();
        assert!(make_config(&settings, None).is_err());
        settings.upstreams = (0..5)
            .map(|_| Upstream {
                ip: "1.1.1.1".into(),
                host: "1.1.1.1".into(),
            })
            .collect();
        assert!(make_config(&settings, None).is_err());
        assert!(nextjson::nextdecode::<Settings>(br#"{"verify":false}"#).is_err());
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
        let host = std::env::var("HEDONE_DNS_TEST_HOST").unwrap_or_else(|_| "example.com".into());
        let addresses = encrypted(dns, host, RrType::A).await.unwrap();
        assert!(!addresses.is_empty());
        assert!(
            addresses
                .iter()
                .all(|ip| crate::network_policy::allowed_ip(*ip))
        );
    }
}
