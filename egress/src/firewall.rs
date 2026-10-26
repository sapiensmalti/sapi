//! Namespace firewall. Applied once, as root, before anything listens and
//! before the agent container exists. If any rule fails to apply the process
//! exits non-zero and the launcher never starts the agent: fail closed.
//!
//! Everything the agent emits is locally generated traffic in this network
//! namespace, so the OUTPUT chains are the whole story:
//!
//! * filter OUTPUT policy DROP; allow loopback and the proxy's own cgroup.
//! * nat OUTPUT: outside the proxy cgroup, redirect TCP 443 → TLS filter,
//!   TCP 80 → HTTP filter, UDP/TCP 53 → fake DNS.
//! * ip6tables: policy DROP, loopback only. No IPv6 egress at all.
//!
//! Exemption is tied to socket cgroup membership, never uid: root in the
//! agent may change Unix identity, but cannot enter the proxy's cgroup.
//! The agent has a private, read-only cgroup hierarchy and no `SYS_ADMIN`,
//! `NET_ADMIN`, or `NET_RAW`. The proxy needs a host cgroup namespace to
//! discover its exact, non-root cgroup-v2 path; unsupported setups fail closed.

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
pub fn rules(cgroup: &str, ports: Ports) -> Vec<(&'static str, Vec<String>)> {
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
        // A sidecar can be restarted in an existing namespace. Start from an
        // empty built-in chain so restarts cannot accumulate duplicate rules.
        // Policies are already DROP, so flushing cannot open a window.
        v4(&["-F", "OUTPUT"]),
        v4(&["-F", "INPUT"]),
        v4(&["-F", "FORWARD"]),
        v4(&["-t", "nat", "-F", "OUTPUT"]),
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
        // Redirected packets still carry their original output interface when
        // the filter hook runs; only the destination has become 127.0.0.1.
        // Accept exactly our three listener ports there and nothing else.
        v4(&[
            "-A",
            "OUTPUT",
            "-d",
            "127.0.0.1",
            "-p",
            "udp",
            "--dport",
            &dns,
            "-j",
            "ACCEPT",
        ]),
        v4(&[
            "-A",
            "OUTPUT",
            "-d",
            "127.0.0.1",
            "-p",
            "tcp",
            "--dport",
            &dns,
            "-j",
            "ACCEPT",
        ]),
        v4(&[
            "-A",
            "OUTPUT",
            "-d",
            "127.0.0.1",
            "-p",
            "tcp",
            "--dport",
            &tls,
            "-j",
            "ACCEPT",
        ]),
        v4(&[
            "-A",
            "OUTPUT",
            "-d",
            "127.0.0.1",
            "-p",
            "tcp",
            "--dport",
            &http,
            "-j",
            "ACCEPT",
        ]),
        v4(&[
            "-A", "OUTPUT", "-m", "cgroup", "--path", cgroup, "-j", "ACCEPT",
        ]),
        // Every other cgroup is filtered, even if its process uid is root or
        // equals the proxy uid. Identity changes cannot acquire exemption.
        // --- IPv4 nat: transparent redirection outside the proxy cgroup ---
        v4(&["-t", "nat", "-A", "OUTPUT", "-o", "lo", "-j", "RETURN"]),
        v4(&[
            "-t", "nat", "-A", "OUTPUT", "-m", "cgroup", "--path", cgroup, "-j", "RETURN",
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
        v6(&["-F", "OUTPUT"]),
        v6(&["-F", "INPUT"]),
        v6(&["-F", "FORWARD"]),
        v6(&["-A", "INPUT", "-i", "lo", "-j", "ACCEPT"]),
        v6(&["-A", "OUTPUT", "-o", "lo", "-j", "ACCEPT"]),
    ]
}

/// Parse the exact unified cgroup path visible in the host cgroup namespace.
/// Never accept the hierarchy root: exempting it would exempt every agent.
pub fn parse_cgroup(contents: &str) -> Result<&str> {
    let mut paths = contents
        .lines()
        .filter_map(|line| line.strip_prefix("0::/"));
    let path = paths.next().context("cgroup v2 is required")?;
    if paths.next().is_some()
        || path.is_empty()
        || path.len() > 4095
        || path.chars().any(|c| c.is_control() || c.is_whitespace())
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        bail!("invalid/root cgroup path; start the sidecar with --cgroupns host");
    }
    Ok(path)
}

/// Apply the rules. Must run as root with `CAP_NET_ADMIN` in the host cgroup
/// namespace. No uid-based or unsupported-kernel fallback is permitted.
pub fn apply(ports: Ports) -> Result<()> {
    let membership =
        std::fs::read_to_string("/proc/self/cgroup").context("read cgroup membership")?;
    let cgroup = parse_cgroup(&membership)?;
    for (bin, args) in rules(cgroup, ports) {
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        run(bin, &refs)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cgroup_requires_an_exact_non_root_unified_path() {
        for valid in [
            "system.slice/docker-012345.scope",
            "docker/012345",
            "user.slice/user-1000.slice/docker-012345.scope",
        ] {
            assert_eq!(parse_cgroup(&format!("0::/{valid}\n")).unwrap(), valid);
        }
        for invalid in [
            "",
            "0::/\n",
            "1:net_cls:/docker/id\n",
            "0::relative\n",
            "0::/a/../b\n",
            "0::/a/./b\n",
            "0::/a//b\n",
            "0::/a/\n",
            "0::/a b\n",
            "0::/a\t\n",
            "0::/a\0b\n",
            "0::/a\n0::/b\n",
        ] {
            assert!(parse_cgroup(invalid).is_err(), "{invalid:?}");
        }
        assert!(parse_cgroup(&format!("0::/{}", "a".repeat(4096))).is_err());
    }

    #[test]
    fn rules_exempt_only_the_proxy_cgroup_and_redirect_the_three_ports() {
        let r = rules(
            "system.slice/docker-proxy.scope",
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
        for chain in ["OUTPUT", "INPUT", "FORWARD"] {
            assert!(joined.iter().any(|l| l == &format!("iptables -F {chain}")));
            assert!(joined.iter().any(|l| l == &format!("ip6tables -F {chain}")));
        }
        assert!(joined.iter().any(|l| l == "iptables -t nat -F OUTPUT"));
        assert!(joined
            .iter()
            .any(|l| l.contains("-m cgroup --path system.slice/docker-proxy.scope -j ACCEPT")));
        assert_eq!(
            joined
                .iter()
                .filter(|l| l.contains("-m cgroup --path "))
                .count(),
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
        // Every ACCEPT is one of: loopback interface, a redirected destination
        // on one of our three ports, the proxy cgroup, or an established reply.
        assert!(joined
            .iter()
            .all(|l| !l.contains("--uid-owner") && !l.contains("-m owner")));
        for l in joined.iter().filter(|l| l.contains("-j ACCEPT")) {
            assert!(
                l.contains(" lo ")
                    || l.contains("-d 127.0.0.1 ")
                    || l.contains("-m cgroup --path system.slice/docker-proxy.scope ")
                    || l.contains("conntrack"),
                "unexpected ACCEPT: {l}"
            );
        }
        assert_eq!(
            joined
                .iter()
                .filter(|l| l.contains("-d 127.0.0.1 "))
                .count(),
            4
        );
        for p in ["15053", "15443", "15080"] {
            assert!(
                joined
                    .iter()
                    .any(|l| l.contains(&format!("-d 127.0.0.1 -p tcp --dport {p} -j ACCEPT"))),
                "{p}"
            );
        }
        assert!(joined
            .iter()
            .any(|l| l.contains("-d 127.0.0.1 -p udp --dport 15053 -j ACCEPT")));
    }
}
