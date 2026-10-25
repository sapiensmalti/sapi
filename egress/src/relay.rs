//! Connect-by-name relay with address hygiene.
//!
//! The upstream address is always the result of resolving the *name* the
//! client asked for — never the address the client tried to connect to. A
//! client therefore cannot pair an allowed SNI with an attacker's IP. Names
//! that resolve to private, loopback, link-local or otherwise non-public
//! ranges are refused unless explicitly permitted (DNS rebinding defence).

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use tokio::io::{copy_bidirectional, AsyncWriteExt};
use tokio::net::TcpStream;

/// Connect timeout.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Hard ceiling on a single relayed connection.
pub const MAX_CONNECTION: Duration = Duration::from_secs(3600);

/// Why a relay could not be established.
#[derive(Debug)]
pub enum RelayError {
    /// The name did not resolve.
    Resolve(String),
    /// All resolved addresses were non-public.
    NonPublic(Vec<IpAddr>),
    /// TCP connect failed or timed out.
    Connect(String),
}

impl std::fmt::Display for RelayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RelayError::Resolve(e) => write!(f, "resolve: {e}"),
            RelayError::NonPublic(a) => write!(f, "refused non-public address(es): {a:?}"),
            RelayError::Connect(e) => write!(f, "connect: {e}"),
        }
    }
}

/// Is this an address a public service may legitimately have?
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => is_public_v4(v4),
            None => is_public_v6(v6),
        },
    }
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    let (a, b) = (
        o.first().copied().unwrap_or(0),
        o.get(1).copied().unwrap_or(0),
    );
    !(ip.is_private()
        || ip.is_loopback()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_multicast()
        || ip.is_unspecified()
        || ip.is_documentation()
        || a == 0
        || (a == 100 && (64..=127).contains(&b)) // CGNAT 100.64/10
        || (a == 198 && (18..=19).contains(&b)) // benchmarking 198.18/15 (our sink)
        || a >= 240) // reserved + 255/8
}

fn is_public_v6(ip: Ipv6Addr) -> bool {
    let s = ip.segments();
    let first = s.first().copied().unwrap_or(0);
    !(ip.is_loopback()
        || ip.is_unspecified()
        || ip.is_multicast()
        || (first & 0xfe00) == 0xfc00 // unique local fc00::/7
        || (first & 0xffc0) == 0xfe80 // link-local fe80::/10
        || first == 0x2001 && s.get(1) == Some(&0x0db8)) // documentation
}

/// Resolve `host:port`, filter, connect.
pub async fn connect(
    host: &str,
    port: u16,
    allow_private: bool,
) -> Result<(TcpStream, SocketAddr), RelayError> {
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host, port))
        .await
        .map_err(|e| RelayError::Resolve(e.to_string()))?
        .collect();
    if addrs.is_empty() {
        return Err(RelayError::Resolve("no addresses".into()));
    }
    let candidates: Vec<SocketAddr> = if allow_private {
        addrs
    } else {
        let refused: Vec<IpAddr> = addrs
            .iter()
            .map(SocketAddr::ip)
            .filter(|ip| !is_public(*ip))
            .collect();
        let ok: Vec<SocketAddr> = addrs.into_iter().filter(|a| is_public(a.ip())).collect();
        if ok.is_empty() {
            return Err(RelayError::NonPublic(refused));
        }
        ok
    };
    let mut last = String::from("no candidates");
    for addr in candidates {
        match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
            Ok(Ok(s)) => {
                let _ = s.set_nodelay(true);
                return Ok((s, addr));
            }
            Ok(Err(e)) => last = format!("{addr}: {e}"),
            Err(_) => last = format!("{addr}: timeout"),
        }
    }
    Err(RelayError::Connect(last))
}

/// Replay the sniffed head to upstream, then splice both directions until
/// either side closes or the ceiling is hit. Returns (bytes up, bytes down).
pub async fn splice(mut client: TcpStream, mut upstream: TcpStream, head: &[u8]) -> (u64, u64) {
    if upstream.write_all(head).await.is_err() {
        return (0, 0);
    }
    let head_len = u64::try_from(head.len()).unwrap_or(0);
    match tokio::time::timeout(
        MAX_CONNECTION,
        copy_bidirectional(&mut client, &mut upstream),
    )
    .await
    {
        Ok(Ok((up, down))) => (up + head_len, down),
        Ok(Err(_)) | Err(_) => (head_len, 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_filter() {
        for bad in [
            "10.0.0.1",
            "172.16.5.5",
            "192.168.1.1",
            "127.0.0.1",
            "169.254.1.1",
            "0.0.0.0",
            "100.64.0.1",
            "198.18.0.1",
            "224.0.0.1",
            "240.0.0.1",
            "255.255.255.255",
            "::1",
            "fe80::1",
            "fd00::1",
            "::",
            "ff02::1",
            "::ffff:10.0.0.1",
            "2001:db8::1",
        ] {
            let ip: IpAddr = bad.parse().unwrap();
            assert!(!is_public(ip), "{bad} must be non-public");
        }
        for good in [
            "1.1.1.1",
            "8.8.8.8",
            "140.82.112.3",
            "2606:4700::1111",
            "::ffff:1.1.1.1",
        ] {
            let ip: IpAddr = good.parse().unwrap();
            assert!(is_public(ip), "{good} must be public");
        }
    }

    #[tokio::test]
    async fn refuses_loopback_by_default_and_allows_when_asked() {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        match connect("localhost", port, false).await {
            Err(RelayError::NonPublic(_)) => {}
            other => panic!("expected NonPublic, got {other:?}"),
        }
        assert!(connect("localhost", port, true).await.is_ok());
    }
}
