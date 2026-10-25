//! End-to-end tests of the running sidecar, without iptables or privileges:
//! `--no-firewall` keeps everything in user space and `--test-upstream`
//! points every allowed connection at a local echo server.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Echo server: whatever arrives is written straight back.
fn echo_server() -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    thread::spawn(move || {
        for s in l.incoming().flatten() {
            thread::spawn(move || {
                let mut s = s;
                let mut buf = [0u8; 4096];
                while let Ok(n) = s.read(&mut buf) {
                    if n == 0 || s.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            });
        }
    });
    addr
}

struct Proxy {
    child: Child,
    dns: u16,
    tls: u16,
    http: u16,
    log_rx: mpsc::Receiver<String>,
}

impl Proxy {
    fn start(allow: &str, upstream: SocketAddr) -> Self {
        let (dns, tls, http) = (free_port(), free_port(), free_port());
        let ready = std::env::temp_dir().join(format!("egress-ready-{}", std::process::id()));
        let _ = std::fs::remove_file(&ready);
        let mut child = Command::new(env!("CARGO_BIN_EXE_sapi-egress"))
            .args([
                "--no-firewall",
                "--allow",
                allow,
                "--bind",
                "127.0.0.1",
                "--dns-port",
                &dns.to_string(),
                "--tls-port",
                &tls.to_string(),
                "--http-port",
                &http.to_string(),
                "--ready-file",
                ready.to_str().unwrap(),
                "--test-upstream",
                &upstream.to_string(),
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, log_rx) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let _ = tx.send(line);
            }
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ready.exists() {
            assert!(Instant::now() < deadline, "proxy did not become ready");
            thread::sleep(Duration::from_millis(20));
        }
        Self {
            child,
            dns,
            tls,
            http,
            log_rx,
        }
    }

    fn next_log(&self) -> serde_json::Value {
        let line = self
            .log_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("log line");
        serde_json::from_str(&line).unwrap()
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn client_hello(sni: &str) -> Vec<u8> {
    let n = sni.as_bytes();
    let mut sni_ext = Vec::new();
    sni_ext.extend_from_slice(&u16::try_from(n.len() + 3).unwrap().to_be_bytes());
    sni_ext.push(0);
    sni_ext.extend_from_slice(&u16::try_from(n.len()).unwrap().to_be_bytes());
    sni_ext.extend_from_slice(n);
    let mut exts = Vec::new();
    exts.extend_from_slice(&0u16.to_be_bytes());
    exts.extend_from_slice(&u16::try_from(sni_ext.len()).unwrap().to_be_bytes());
    exts.extend_from_slice(&sni_ext);
    let mut body = vec![0x03, 0x03];
    body.extend_from_slice(&[0u8; 32]);
    body.push(0);
    body.extend_from_slice(&[0x00, 0x02, 0x13, 0x01, 0x01, 0x00]);
    body.extend_from_slice(&u16::try_from(exts.len()).unwrap().to_be_bytes());
    body.extend_from_slice(&exts);
    let mut hs = vec![0x01];
    hs.extend_from_slice(&u32::try_from(body.len()).unwrap().to_be_bytes()[1..]);
    hs.extend_from_slice(&body);
    let mut rec = vec![0x16, 0x03, 0x01];
    rec.extend_from_slice(&u16::try_from(hs.len()).unwrap().to_be_bytes());
    rec.extend_from_slice(&hs);
    rec
}

fn dns_query(name: &str) -> Vec<u8> {
    let mut q = vec![0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
    for label in name.split('.') {
        q.push(u8::try_from(label.len()).unwrap());
        q.extend_from_slice(label.as_bytes());
    }
    q.push(0);
    q.extend_from_slice(&[0, 1, 0, 1]);
    q
}

fn send_and_read(port: u16, data: &[u8]) -> Vec<u8> {
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    s.write_all(data).unwrap();
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    // Read until we have at least `data.len()` bytes echoed, or the peer closes / times out.
    loop {
        match s.read(&mut buf) {
            Ok(n) if n > 0 => {
                out.extend_from_slice(&buf[..n]);
                if out.len() >= data.len() {
                    break;
                }
            }
            _ => break,
        }
    }
    out
}

#[test]
fn dns_allowed_gets_sink_denied_gets_nxdomain() {
    let p = Proxy::start("good.example *.ok.example", echo_server());
    let sock = UdpSocket::bind("127.0.0.1:0").unwrap();
    sock.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let mut buf = [0u8; 512];

    sock.send_to(&dns_query("good.example"), ("127.0.0.1", p.dns))
        .unwrap();
    let (n, _) = sock.recv_from(&mut buf).unwrap();
    assert_eq!(buf[3] & 0x0F, 0, "NOERROR");
    assert!(buf[..n].ends_with(&[198, 18, 0, 1]));
    assert_eq!(p.next_log()["ev"], "allow");

    sock.send_to(&dns_query("sub.ok.example"), ("127.0.0.1", p.dns))
        .unwrap();
    let (_, _) = sock.recv_from(&mut buf).unwrap();
    assert_eq!(buf[3] & 0x0F, 0);
    assert_eq!(p.next_log()["ev"], "allow");

    sock.send_to(&dns_query("evil.example"), ("127.0.0.1", p.dns))
        .unwrap();
    let (n, _) = sock.recv_from(&mut buf).unwrap();
    assert_eq!(buf[3] & 0x0F, 3, "NXDOMAIN");
    assert_eq!(&buf[6..8], &[0, 0]);
    assert_eq!(n, dns_query("evil.example").len());
    let l = p.next_log();
    assert_eq!(l["ev"], "deny");
    assert_eq!(l["host"], "evil.example");
    assert_eq!(l["proto"], "dns");
}

#[test]
fn tls_allowed_is_relayed_denied_is_closed() {
    let p = Proxy::start("good.example", echo_server());
    let hello = client_hello("good.example");
    let echoed = send_and_read(p.tls, &hello);
    assert_eq!(
        echoed, hello,
        "the ClientHello must reach upstream intact and come back from the echo server"
    );

    let denied = send_and_read(p.tls, &client_hello("evil.example"));
    assert!(
        denied.is_empty(),
        "denied TLS connection must be closed without data"
    );
    // Log order: the denied event is synchronous; the allowed event is logged when the relay ends.
    let mut saw_deny = false;
    for _ in 0..2 {
        let l = p.next_log();
        if l["ev"] == "deny" {
            assert_eq!(l["host"], "evil.example");
            assert_eq!(l["port"], 443);
            saw_deny = true;
        }
    }
    assert!(saw_deny);
}

#[test]
fn http_allowed_is_relayed_denied_gets_403() {
    let p = Proxy::start("deb.debian.org", echo_server());
    let req = b"GET /debian/dists/ HTTP/1.1\r\nHost: deb.debian.org\r\nUser-Agent: apt\r\n\r\n";
    assert_eq!(send_and_read(p.http, req), req.to_vec());

    let bad = b"GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n";
    let resp = send_and_read(p.http, bad);
    assert!(
        resp.starts_with(b"HTTP/1.1 403"),
        "{}",
        String::from_utf8_lossy(&resp)
    );

    // Absolute-form target is authoritative even when Host is allowed.
    let smuggle = b"GET http://evil.example/ HTTP/1.1\r\nHost: deb.debian.org\r\n\r\n";
    assert!(send_and_read(p.http, smuggle).starts_with(b"HTTP/1.1 403"));
}

#[test]
fn garbage_is_denied_without_reaching_upstream() {
    let p = Proxy::start("good.example", echo_server());
    assert_eq!(send_and_read(p.tls, b"SSH-2.0-OpenSSH_9.0\r\n").len(), 0);
    assert_eq!(
        send_and_read(p.tls, &[0x16, 0x03, 0x01, 0x00, 0x05, 0x02, 0, 0, 0, 0]).len(),
        0
    );
    let l = p.next_log();
    assert_eq!(l["ev"], "deny");
    assert!(l["host"].is_null());
}

#[test]
fn empty_allowlist_denies_everything_but_runs() {
    let p = Proxy::start("", echo_server());
    assert_eq!(
        send_and_read(p.tls, &client_hello("anything.example")).len(),
        0
    );
    assert_eq!(p.next_log()["ev"], "deny");
}

#[test]
fn rejects_invalid_allowlist_at_startup() {
    let out = Command::new(env!("CARGO_BIN_EXE_sapi-egress"))
        .args([
            "--no-firewall",
            "--allow",
            "*.",
            "--ready-file",
            "/dev/null",
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("invalid allowlist entry"));
}
