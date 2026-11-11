//! Connection lifecycle around Courierust's public HTTP/1 API.
//! DNS policy belongs to network_policy; this module never resolves a hostname.
use courierust::{
    courierust_client::{ClientConfig, h1::H1Connection},
    courierust_net,
    courierust_tls::{ClientConfig as TlsConfig, RootStore, TlsConnector},
};
use std::{
    io,
    net::SocketAddr,
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{Semaphore, SemaphorePermit};

const MAX_ADDRESSES: usize = 16;
const CONNECT_SLICE: Duration = Duration::from_millis(1500);
const IDLE_TTL: Duration = Duration::from_secs(15);
const IDLE_PER_ORIGIN: usize = 2;
static IDLE_SLOTS: Semaphore = Semaphore::const_new(8);

pub(crate) fn remaining(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "request timed out"))
}

struct Idle {
    connection: H1Connection,
    expires: Instant,
    _slot: SemaphorePermit<'static>,
}

pub(crate) struct Connections {
    addresses: Vec<SocketAddr>,
    preferred: AtomicUsize,
    idle: Mutex<Vec<Idle>>,
}

impl Connections {
    pub(crate) fn new(addresses: &[SocketAddr], port: u16) -> Result<Self, String> {
        if addresses.is_empty() {
            return Err("缺少已校验的 DNS 地址".into());
        }
        if addresses.iter().any(|a| a.port() != port) {
            return Err("已校验地址端口与目标不一致".into());
        }
        // Interleave families before applying the cap, so a long AAAA answer
        // cannot push every A record out of the bounded candidate list.
        let ipv6_first = addresses[0].is_ipv6();
        let mut primary = addresses.iter().filter(|a| a.is_ipv6() == ipv6_first);
        let mut secondary = addresses.iter().filter(|a| a.is_ipv6() != ipv6_first);
        let mut ordered = Vec::with_capacity(MAX_ADDRESSES);
        loop {
            let pair = [primary.next(), secondary.next()];
            if pair.iter().all(Option::is_none) || ordered.len() == MAX_ADDRESSES {
                break;
            }
            for address in pair.into_iter().flatten() {
                if ordered.len() < MAX_ADDRESSES && !ordered.contains(address) {
                    ordered.push(*address);
                }
            }
        }
        Ok(Self {
            addresses: ordered,
            preferred: AtomicUsize::new(0),
            idle: Mutex::new(Vec::new()),
        })
    }

    pub(crate) fn take(&self) -> Option<H1Connection> {
        let mut idle = self.idle.lock().ok()?;
        let now = Instant::now();
        idle.retain(|entry| entry.expires > now);
        while let Some(entry) = idle.pop() {
            if entry.connection.is_reusable() && entry.connection.is_alive() {
                return Some(entry.connection);
            }
        }
        None
    }

    pub(crate) fn recycle(&self, connection: H1Connection) {
        if !connection.is_reusable() {
            return;
        }
        let Ok(mut idle) = self.idle.lock() else {
            return;
        };
        let now = Instant::now();
        idle.retain(|entry| entry.expires > now);
        if idle.len() >= IDLE_PER_ORIGIN {
            return;
        }
        let Ok(slot) = IDLE_SLOTS.try_acquire() else {
            return;
        };
        idle.push(Idle {
            connection,
            expires: now + IDLE_TTL,
            _slot: slot,
        });
    }

    pub(crate) fn connect(
        &self,
        hostname: &str,
        roots: Option<&RootStore>,
        config: &ClientConfig,
        deadline: Instant,
    ) -> io::Result<H1Connection> {
        let preferred = self.preferred.load(Ordering::Relaxed);
        let mut last = io::Error::other("所有已校验地址均连接失败");
        for offset in 0..self.addresses.len() {
            let index = (preferred + offset) % self.addresses.len();
            let timeout = remaining(deadline)?.min(CONNECT_SLICE);
            let socket = match courierust_net::connect(&self.addresses[index], Some(timeout)) {
                Ok(socket) => socket,
                Err(error) => {
                    last = io::Error::other(error.to_string());
                    continue;
                }
            };
            let mut config = config.clone();
            config.handshake_timeout = Some(remaining(deadline)?);
            config.read_timeout = Some(remaining(deadline)?);
            // Fresh connectors never share session tickets. Persistent HTTP
            // connections are reused only after a complete verified handshake.
            let tls = roots
                .map(|roots| {
                    let now = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map_err(io::Error::other)?
                        .as_secs()
                        .try_into()
                        .map_err(io::Error::other)?;
                    Ok::<_, io::Error>(TlsConnector::new(TlsConfig {
                        roots: roots.clone(),
                        verify: true,
                        now,
                        alpn: vec![b"http/1.1".to_vec()],
                        ..Default::default()
                    }))
                })
                .transpose()?;
            // A TLS failure is terminal: it must not trigger a weaker protocol,
            // another trust policy, or transmission of an application request.
            let connection = H1Connection::from_socket(socket, tls.as_ref(), hostname, &config)
                .map_err(|e| io::Error::other(e.to_string()))?;
            self.preferred.store(index, Ordering::Relaxed);
            return Ok(connection);
        }
        Err(last)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_cap_preserves_both_families_and_rejects_any_wrong_port() {
        let mut addresses: Vec<SocketAddr> = (1..=20)
            .map(|i| format!("[2001:db8::{i}]:443").parse().unwrap())
            .collect();
        addresses.push("192.0.2.1:443".parse().unwrap());
        let connections = Connections::new(&addresses, 443).unwrap();
        assert_eq!(connections.addresses.len(), MAX_ADDRESSES);
        assert!(connections.addresses[1].is_ipv4());
        addresses.push("192.0.2.2:80".parse().unwrap());
        assert!(Connections::new(&addresses, 443).is_err());
        assert!(Connections::new(&[], 443).is_err());
    }
}
