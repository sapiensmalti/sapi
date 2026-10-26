//! `sapi-egress` — transparent egress allowlist sidecar.
//!
//! Runs in the network namespace the agent container shares. Installs the
//! namespace firewall, binds three loopback listeners (fake DNS, TLS-SNI
//! filter, HTTP-Host filter), drops to an unprivileged uid, writes a ready
//! marker, then serves. Every decision is one JSON line on stdout.
//!
//! Policy is a hostname allowlist and nothing else. There is no bypass flag.

#![forbid(unsafe_code)]
#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing
    )
)]

mod allow;
mod dns;
mod firewall;
mod relay;
mod sniff;

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use clap::Parser;
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::Semaphore;

use allow::Allowlist;
use sniff::Sniff;

const HEAD_LIMIT: usize = 16 * 1024;
const HEAD_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 1024;

/// sapi egress sidecar: hostname allowlist for a shared network namespace.
#[derive(Parser, Debug)]
#[command(name = "sapi-egress", version, about)]
struct Cli {
    /// Allowed hosts: `host`, `*.suffix`, optional `:port`; comma/space separated.
    #[arg(long, env = "EGRESS_ALLOW", default_value = "")]
    allow: String,
    /// Unprivileged uid to run as after setup (not a firewall exemption).
    #[arg(long, env = "EGRESS_UID", default_value_t = 65532)]
    uid: u32,
    /// Address the listeners bind to.
    #[arg(long, default_value = "127.0.0.1")]
    bind: IpAddr,
    /// Fake DNS port.
    #[arg(long, default_value_t = 15053)]
    dns_port: u16,
    /// TLS filter port (REDIRECT target for 443).
    #[arg(long, default_value_t = 15443)]
    tls_port: u16,
    /// HTTP filter port (REDIRECT target for 80).
    #[arg(long, default_value_t = 15080)]
    http_port: u16,
    /// Written once the firewall is up and the listeners are bound.
    #[arg(long, default_value = "/run/egress/ready")]
    ready_file: PathBuf,
    /// Permit upstream addresses in private/loopback ranges (test builds only).
    #[cfg(feature = "test-utils")]
    #[arg(long)]
    allow_private: bool,
    /// Do not touch iptables and do not drop privileges (test builds only).
    #[cfg(feature = "test-utils")]
    #[arg(long)]
    no_firewall: bool,
    /// Send every upstream connection here (test builds only).
    #[cfg(feature = "test-utils")]
    #[arg(long)]
    test_upstream: Option<SocketAddr>,
}

#[derive(Clone)]
struct State {
    allow: Arc<Allowlist>,
    allow_private: bool,
    test_upstream: Option<SocketAddr>,
    limiter: Arc<Semaphore>,
}

#[cfg(feature = "test-utils")]
fn execution_options(cli: &Cli) -> (bool, bool, Option<SocketAddr>) {
    (cli.no_firewall, cli.allow_private, cli.test_upstream)
}

#[cfg(not(feature = "test-utils"))]
fn execution_options(_cli: &Cli) -> (bool, bool, Option<SocketAddr>) {
    (false, false, None)
}

#[derive(Serialize)]
struct Event<'a> {
    t: u64,
    ev: &'a str,
    proto: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    host: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    upstream: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    up: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    down: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ms: Option<u128>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn emit(e: &Event<'_>) {
    if let Ok(s) = serde_json::to_string(e) {
        println!("{s}");
    }
}

fn log_simple(ev: &str, proto: &str, host: Option<&str>, port: Option<u16>, reason: Option<&str>) {
    emit(&Event {
        t: now(),
        ev,
        proto,
        host,
        port,
        reason,
        upstream: None,
        up: None,
        down: None,
        ms: None,
    });
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let allow = Allowlist::parse(&cli.allow).context("EGRESS_ALLOW")?;
    if allow.is_empty() {
        eprintln!("sapi-egress: warning: the allowlist is empty; every connection will be denied");
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("runtime")?;
    rt.block_on(run(cli, allow))
}

fn publish_ready(path: &std::path::Path, contents: &[u8]) -> Result<()> {
    let partial = path.with_extension(format!("partial.{}", std::process::id()));
    let mut owned = false;
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&partial)
            .with_context(|| format!("create {}", partial.display()))?;
        owned = true;
        std::io::Write::write_all(&mut file, contents).context("write readiness")?;
        std::fs::rename(&partial, path).context("publish readiness")
    })();
    if result.is_err() && owned {
        let _ = std::fs::remove_file(&partial);
    }
    result
}

async fn run(cli: Cli, allow: Allowlist) -> Result<()> {
    let (no_firewall, allow_private, test_upstream) = execution_options(&cli);
    // A container restart must never expose last boot's readiness. The
    // launcher additionally mounts /run/egress as a fresh tmpfs.
    match std::fs::remove_file(&cli.ready_file) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            return Err(e).with_context(|| format!("remove stale {}", cli.ready_file.display()))
        }
    }
    let ports = firewall::Ports {
        dns: cli.dns_port,
        tls: cli.tls_port,
        http: cli.http_port,
    };

    // 1. Firewall first. Only sockets in this container's cgroup are exempt;
    // root in the agent cannot acquire exemption by changing Unix identity.
    if !no_firewall {
        firewall::apply(ports).context("firewall (requires cgroup v2 and --cgroupns host)")?;
    }

    // 2. Bind while still privileged (ports are >1024, but order matters for readiness).
    let dns_udp = UdpSocket::bind((cli.bind, cli.dns_port))
        .await
        .context("bind dns udp")?;
    let dns_tcp = TcpListener::bind((cli.bind, cli.dns_port))
        .await
        .context("bind dns tcp")?;
    let tls = TcpListener::bind((cli.bind, cli.tls_port))
        .await
        .context("bind tls")?;
    let http = TcpListener::bind((cli.bind, cli.http_port))
        .await
        .context("bind http")?;

    // 3. Create the readiness directory while privileged. /run is a fresh
    // tmpfs in production; iptables also uses it for xtables.lock.
    if let Some(dir) = cli.ready_file.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
        if !no_firewall {
            use std::os::unix::fs::PermissionsExt;
            // Only a readiness marker lives here, and the agent has a
            // different mount namespace. The proxy uid must be able to write.
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o777))
                .with_context(|| format!("chmod {}", dir.display()))?;
        }
    }

    // 4. Drop privileges for good.
    if !no_firewall {
        drop_privileges(cli.uid)?;
    }

    // 5. Signal readiness. The launcher waits for this before creating the agent.
    let readiness = b"cgroup-v2\n".to_vec();
    #[cfg(feature = "test-utils")]
    let readiness = if no_firewall {
        // Tests request port 0 and receive the ports of bound sockets. No
        // close-and-rebind reservation race or production bypass marker.
        serde_json::to_vec(&serde_json::json!({
            "policy": "test-no-firewall",
            "dns": dns_udp.local_addr()?.port(),
            "dns_tcp": dns_tcp.local_addr()?.port(),
            "tls": tls.local_addr()?.port(),
            "http": http.local_addr()?.port(),
        }))?
    } else {
        readiness
    };
    publish_ready(&cli.ready_file, &readiness)?;
    eprintln!(
        "sapi-egress: ready · {} allowlist entries · dns :{} tls :{} http :{} · uid {}",
        allow.len(),
        dns_udp.local_addr()?.port(),
        tls.local_addr()?.port(),
        http.local_addr()?.port(),
        cli.uid
    );

    let state = State {
        allow: Arc::new(allow),
        allow_private,
        test_upstream,
        limiter: Arc::new(Semaphore::new(MAX_CONNECTIONS)),
    };

    let s1 = state.clone();
    let s2 = state.clone();
    let s3 = state.clone();
    let s4 = state;
    tokio::select! {
        r = serve_dns_udp(dns_udp, s1) => r,
        r = serve_dns_tcp(dns_tcp, s2) => r,
        r = serve_tcp(tls, 443, "tls", s3) => r,
        r = serve_tcp(http, 80, "http", s4) => r,
        _ = tokio::signal::ctrl_c() => Ok(()),
        () = sigterm() => Ok(()),
    }
}

async fn sigterm() {
    if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
        s.recv().await;
    } else {
        std::future::pending::<()>().await;
    }
}

fn drop_privileges(uid: u32) -> Result<()> {
    use nix::unistd::{getgid, getuid, setgid, setgroups, setuid, Gid, Uid};
    if !getuid().is_root() {
        bail!(
            "must start as root to apply the firewall (uid {})",
            getuid()
        );
    }
    let user = Uid::from_raw(uid);
    let group = Gid::from_raw(uid);
    setgroups(&[]).context("setgroups")?;
    setgid(group).context("setgid")?;
    setuid(user).context("setuid")?;
    // Verify the drop is real and irreversible.
    if getuid() != user || getgid() != group {
        bail!("privilege drop did not take effect");
    }
    if setuid(Uid::from_raw(0)).is_ok() {
        bail!("privilege drop is reversible; refusing to run");
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// DNS
// ---------------------------------------------------------------------------

fn answer_dns(state: &State, msg: &[u8]) -> Option<Vec<u8>> {
    let q = dns::parse_question(msg)?;
    // Allowed if the name is allowed on either filtered port.
    let allowed = state.allow.allows(&q.name, 443) || state.allow.allows(&q.name, 80);
    log_simple(
        if allowed { "allow" } else { "deny" },
        "dns",
        Some(&q.name),
        None,
        if allowed {
            None
        } else {
            Some("not in allowlist")
        },
    );
    dns::build_response(msg, &q, allowed)
}

async fn serve_dns_udp(sock: UdpSocket, state: State) -> Result<()> {
    let mut buf = vec![0u8; 1500];
    loop {
        let Ok((n, peer)) = sock.recv_from(&mut buf).await else {
            continue;
        };
        if let Some(resp) = answer_dns(&state, buf.get(..n).unwrap_or_default()) {
            let _ = sock.send_to(&resp, peer).await;
        }
    }
}

async fn serve_dns_tcp(listener: TcpListener, state: State) -> Result<()> {
    loop {
        let Ok((mut stream, _)) = listener.accept().await else {
            continue;
        };
        let state = state.clone();
        tokio::spawn(async move {
            let mut len = [0u8; 2];
            if tokio::time::timeout(HEAD_TIMEOUT, stream.read_exact(&mut len))
                .await
                .is_err()
            {
                return;
            }
            let n = usize::from(u16::from_be_bytes(len));
            if n == 0 || n > 4096 {
                return;
            }
            let mut msg = vec![0u8; n];
            if tokio::time::timeout(HEAD_TIMEOUT, stream.read_exact(&mut msg))
                .await
                .is_err()
            {
                return;
            }
            if let Some(resp) = answer_dns(&state, &msg) {
                let Ok(l) = u16::try_from(resp.len()) else {
                    return;
                };
                let _ = stream.write_all(&l.to_be_bytes()).await;
                let _ = stream.write_all(&resp).await;
            }
        });
    }
}

// ---------------------------------------------------------------------------
// TLS / HTTP
// ---------------------------------------------------------------------------

async fn serve_tcp(
    listener: TcpListener,
    port: u16,
    proto: &'static str,
    state: State,
) -> Result<()> {
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        let Ok(permit) = Arc::clone(&state.limiter).acquire_owned().await else {
            continue;
        };
        let state = state.clone();
        tokio::spawn(async move {
            handle(stream, port, proto, &state).await;
            drop(permit);
        });
    }
}

async fn read_head(
    stream: &mut TcpStream,
    sniff: fn(&[u8]) -> Sniff,
) -> Result<(Vec<u8>, String), &'static str> {
    let mut buf = Vec::with_capacity(2048);
    let deadline = tokio::time::Instant::now() + HEAD_TIMEOUT;
    loop {
        match sniff(&buf) {
            Sniff::Host(h) if buf.len() <= HEAD_LIMIT => return Ok((buf, h)),
            Sniff::Host(_) => return Err("header too large"),
            Sniff::Invalid => return Err("unrecognised protocol or no hostname"),
            Sniff::Incomplete => {}
        }
        if buf.len() >= HEAD_LIMIT {
            return Err("header too large");
        }
        let mut chunk = [0u8; 4096];
        let n = match tokio::time::timeout_at(deadline, stream.read(&mut chunk)).await {
            Ok(Ok(0)) => return Err("closed before hostname"),
            Ok(Ok(n)) => n,
            Ok(Err(_)) => return Err("read error"),
            Err(_) => return Err("timeout before hostname"),
        };
        buf.extend_from_slice(chunk.get(..n).unwrap_or_default());
    }
}

async fn handle(mut client: TcpStream, port: u16, proto: &'static str, state: &State) {
    let started = Instant::now();
    let sniffer: fn(&[u8]) -> Sniff = if proto == "tls" {
        sniff::tls_sni
    } else {
        sniff::http_host
    };
    let (head, host) = match read_head(&mut client, sniffer).await {
        Ok(x) => x,
        Err(reason) => {
            log_simple("deny", proto, None, Some(port), Some(reason));
            return;
        }
    };
    if !state.allow.allows(&host, port) {
        log_simple(
            "deny",
            proto,
            Some(&host),
            Some(port),
            Some("not in allowlist"),
        );
        // For HTTP we can say why; for TLS a close is the only honest answer.
        if proto == "http" {
            let _ = client
                .write_all(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\nsapi-egress: host not in allowlist\n")
                .await;
        }
        return;
    }
    let connected = match state.test_upstream {
        Some(addr) => tokio::time::timeout(relay::CONNECT_TIMEOUT, TcpStream::connect(addr))
            .await
            .map_err(|_| relay::RelayError::Connect("timeout".into()))
            .and_then(|r| r.map_err(|e| relay::RelayError::Connect(e.to_string())))
            .map(|s| (s, addr)),
        None => relay::connect(&host, port, state.allow_private).await,
    };
    let (upstream, addr) = match connected {
        Ok(x) => x,
        Err(e) => {
            let reason = e.to_string();
            log_simple("deny", proto, Some(&host), Some(port), Some(&reason));
            return;
        }
    };
    let (up, down) = relay::splice(client, upstream, &head).await;
    emit(&Event {
        t: now(),
        ev: "allow",
        proto,
        host: Some(&host),
        port: Some(port),
        reason: None,
        upstream: Some(addr.to_string()),
        up: Some(up),
        down: Some(down),
        ms: Some(started.elapsed().as_millis()),
    });
}

#[cfg(test)]
mod readiness_tests {
    use super::*;

    struct Fixture(PathBuf);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn publishes_complete_marker_and_preserves_foreign_partial() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let fixture = Fixture(
            std::env::temp_dir().join(format!("sapi-ready-{}-{unique}", std::process::id())),
        );
        std::fs::create_dir(&fixture.0).unwrap();
        let path = fixture.0.join("ready");
        let partial = path.with_extension(format!("partial.{}", std::process::id()));
        std::fs::write(&path, "old").unwrap();
        publish_ready(&path, b"cgroup-v2\n").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"cgroup-v2\n");
        assert!(!partial.exists());

        let foreign = fixture.0.join("foreign");
        std::fs::write(&foreign, "keep").unwrap();
        std::os::unix::fs::symlink(&foreign, &partial).unwrap();
        assert!(publish_ready(&path, b"replace").is_err());
        assert_eq!(std::fs::read(&foreign).unwrap(), b"keep");
        assert!(partial.is_symlink());
        assert_eq!(std::fs::read(&path).unwrap(), b"cgroup-v2\n");
        std::fs::remove_file(&partial).unwrap();

        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("keep"), "data").unwrap();
        assert!(publish_ready(&path, b"replace").is_err());
        assert!(!partial.exists());
        assert_eq!(std::fs::read(path.join("keep")).unwrap(), b"data");
    }
}
