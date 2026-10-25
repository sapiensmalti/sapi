//! Namespace firewall. Applied once, as root, before anything listens and
//! before the agent container exists. If any rule fails to apply the process
//! exits non-zero and the launcher never starts the agent: fail closed.
//!
//! Everything the agent emits is locally generated traffic in this network
//! namespace, so the OUTPUT chains are the whole story:
//!
//! * filter OUTPUT policy DROP; allow loopback; allow the proxy's own uid.
//! * nat OUTPUT: for every uid except the proxy, redirect TCP 443 → TLS
//!   filter, TCP 80 → HTTP filter, UDP/TCP 53 → fake DNS.
//! * ip6tables: policy DROP, loopback only. No IPv6 egress at all.
//!
//! The proxy's uid is exempt, which is how its real DNS lookups and upstream
//! connections leave. The agent runs as any other uid and cannot change
//! these rules: it holds neither `NET_ADMIN` nor `NET_RAW`.

use std::process::Command;

use anyhow::{bail, Context, Result};

/// Ports the redirect targets listen on (loopback).
#[derive(Debug, Clone, Copy)]
pub struct Ports {
    /// Fake DNS (UDP and TCP).
    pub dns: u16,
    /// TLS SNI filter.
    pub tls: u16,
    /// HTTP Host filter.
    pub http: u16,
}

fn run(bin: &str, args: &[&str]) -> Result<()> {
    let out = Command::new(bin)
        .args(args)
        .output()
        .with_context(|| format!("exec {bin}"))?;
    if !out.status.success() {
        bail!(
            "{bin} {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// The complete rule set, in order. Pure, so it can be inspected in tests.
#[allow(clippy::too_many_lines)] // it is a table
pub fn rules(uid: u32, ports: Ports) -> Vec<(&'static str, Vec<String>)> {
    let uid = uid.to_string();
    let v4 = |args: &[&str]| {
        (
            "iptables",
            args.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>(),
        )
    };
    let v6 = |args: &[&str]| {
        (
            "ip6tables",
            args.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>(),
        )
    };
    let dns = ports.dns.to_string();
    let tls = ports.tls.to_string();
    let http = ports.http.to_string();
    vec![
        // --- IPv4 filter: default deny ---
        v4(&["-P", "OUTPUT", "DROP"]),
        v4(&["-P", "INPUT", "DROP"]),
        v4(&["-P", "FORWARD", "DROP"]),
        v4(&["-A", "INPUT", "-i", "lo", "-j", "ACCEPT"]),
        v4(&[
            "-A",
            "INPUT",
            "-m",
            "conntrack",
            "--ctstate",
            "ESTABLISHED,RELATED",
            "-j",
            "ACCEPT",
        ]),
        v4(&["-A", "OUTPUT", "-o", "lo", "-j", "ACCEPT"]),
        v4(&[
            "-A",
            "OUTPUT",
            "-m",
            "owner",
            "--uid-owner",
            &uid,
            "-j",
            "ACCEPT",
        ]),
        // Everything else from any other uid to any non-loopback destination is dropped by policy.
        // --- IPv4 nat: transparent redirection for every uid but the proxy ---
        v4(&["-t", "nat", "-A", "OUTPUT", "-o", "lo", "-j", "RETURN"]),
        v4(&[
            "-t",
            "nat",
            "-A",
            "OUTPUT",
            "-m",
            "owner",
            "--uid-owner",
            &uid,
            "-j",
            "RETURN",
        ]),
        v4(&[
            "-t",
            "nat",
            "-A",
            "OUTPUT",
            "-p",
            "udp",
            "--dport",
            "53",
            "-j",
            "REDIRECT",
            "--to-ports",
            &dns,
        ]),
        v4(&[
            "-t",
            "nat",
            "-A",
            "OUTPUT",
            "-p",
            "tcp",
            "--dport",
            "53",
            "-j",
            "REDIRECT",
            "--to-ports",
            &dns,
        ]),
        v4(&[
            "-t",
            "nat",
            "-A",
            "OUTPUT",
            "-p",
            "tcp",
            "--dport",
            "443",
            "-j",
            "REDIRECT",
            "--to-ports",
            &tls,
        ]),
        v4(&[
            "-t",
            "nat",
            "-A",
            "OUTPUT",
            "-p",
            "tcp",
            "--dport",
            "80",
            "-j",
            "REDIRECT",
            "--to-ports",
            &http,
        ]),
        // --- IPv6: nothing leaves ---
        v6(&["-P", "OUTPUT", "DROP"]),
        v6(&["-P", "INPUT", "DROP"]),
        v6(&["-P", "FORWARD", "DROP"]),
        v6(&["-A", "INPUT", "-i", "lo", "-j", "ACCEPT"]),
        v6(&["-A", "OUTPUT", "-o", "lo", "-j", "ACCEPT"]),
    ]
}

/// Apply the rules. Must run as root with `CAP_NET_ADMIN`.
pub fn apply(uid: u32, ports: Ports) -> Result<()> {
    for (bin, args) in rules(uid, ports) {
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        run(bin, &refs)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rules_exempt_only_the_proxy_uid_and_redirect_the_three_ports() {
        let r = rules(
            65532,
            Ports {
                dns: 15053,
                tls: 15443,
                http: 15080,
            },
        );
        let joined: Vec<String> = r
            .iter()
            .map(|(b, a)| format!("{b} {}", a.join(" ")))
            .collect();
        assert!(joined.iter().any(|l| l == "iptables -P OUTPUT DROP"));
        assert!(joined.iter().any(|l| l == "ip6tables -P OUTPUT DROP"));
        assert!(joined
            .iter()
            .any(|l| l.contains("--uid-owner 65532 -j ACCEPT")));
        assert_eq!(
            joined.iter().filter(|l| l.contains("--uid-owner")).count(),
            2
        );
        assert!(joined
            .iter()
            .any(|l| l.contains("--dport 443 -j REDIRECT --to-ports 15443")));
        assert!(joined
            .iter()
            .any(|l| l.contains("--dport 80 -j REDIRECT --to-ports 15080")));
        assert!(joined
            .iter()
            .any(|l| l.contains("-p udp --dport 53 -j REDIRECT --to-ports 15053")));
        assert!(joined
            .iter()
            .any(|l| l.contains("-p tcp --dport 53 -j REDIRECT --to-ports 15053")));
        // Deny-by-default must be installed before any redirect.
        let drop_at = joined
            .iter()
            .position(|l| l == "iptables -P OUTPUT DROP")
            .unwrap();
        let redirect_at = joined.iter().position(|l| l.contains("REDIRECT")).unwrap();
        assert!(drop_at < redirect_at);
        // Nothing ever ACCEPTs non-loopback traffic for other uids.
        assert!(!joined.iter().any(|l| l.contains("-j ACCEPT")
            && !l.contains("lo")
            && !l.contains("uid-owner")
            && !l.contains("conntrack")));
    }
}
