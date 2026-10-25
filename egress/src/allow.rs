//! Hostname allowlist.
//!
//! Entries: `host` (exact), `*.suffix` (any subdomain, at least one label,
//! not the bare suffix), each optionally `:port`. Without a port an entry
//! covers 80 and 443. Matching is case-insensitive; a trailing dot is
//! ignored. Anything else is a parse error — a typo must not become a hole.

use std::fmt;

/// One parsed entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Lower-case host or suffix (without the leading `*.`).
    name: String,
    /// `true` for `*.suffix`.
    wildcard: bool,
    /// Specific port, or `None` for 80 and 443.
    port: Option<u16>,
}

/// The whole list.
#[derive(Debug, Clone, Default)]
pub struct Allowlist {
    entries: Vec<Entry>,
}

/// Why an entry failed to parse.
#[derive(Debug, PartialEq, Eq)]
pub struct ParseError(pub String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid allowlist entry: {}", self.0)
    }
}

impl std::error::Error for ParseError {}

fn valid_label(label: &str) -> bool {
    !label.is_empty()
        && label.len() <= 63
        && label
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        && !label.starts_with('-')
        && !label.ends_with('-')
}

/// Normalise a hostname: lower-case, strip one trailing dot. Returns `None`
/// if it is not a syntactically valid DNS name.
pub fn normalize_host(host: &str) -> Option<String> {
    let h = host
        .trim()
        .strip_suffix('.')
        .unwrap_or(host.trim())
        .to_ascii_lowercase();
    if h.is_empty() || h.len() > 253 || !h.split('.').all(valid_label) {
        return None;
    }
    Some(h)
}

impl Allowlist {
    /// Parse a whitespace- or comma-separated list.
    pub fn parse(text: &str) -> Result<Self, ParseError> {
        let mut entries = Vec::new();
        for raw in text.split([' ', ',', '\n', '\t']).filter(|s| !s.is_empty()) {
            entries.push(Entry::parse(raw)?);
        }
        Ok(Self { entries })
    }

    /// Number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when nothing is allowed.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Is `host:port` allowed? `host` may be in any case, with or without a
    /// trailing dot. Invalid names are never allowed.
    pub fn allows(&self, host: &str, port: u16) -> bool {
        let Some(h) = normalize_host(host) else {
            return false;
        };
        self.entries.iter().any(|e| e.matches(&h, port))
    }
}

impl Entry {
    fn parse(raw: &str) -> Result<Self, ParseError> {
        let (host_part, port) = match raw.rsplit_once(':') {
            Some((h, p)) => {
                let port: u16 = p
                    .parse()
                    .ok()
                    .filter(|p| matches!(p, 80 | 443))
                    .ok_or_else(|| {
                        ParseError(format!("{raw}: only ports 80 and 443 are supported"))
                    })?;
                (h, Some(port))
            }
            None => (raw, None),
        };
        let (wildcard, name) = match host_part.strip_prefix("*.") {
            Some(rest) => (true, rest),
            None => (false, host_part),
        };
        if name.contains('*') {
            return Err(ParseError(format!(
                "{raw}: '*' is only allowed as a leading '*.'"
            )));
        }
        let name = normalize_host(name)
            .ok_or_else(|| ParseError(format!("{raw}: not a valid hostname")))?;
        Ok(Self {
            name,
            wildcard,
            port,
        })
    }

    fn matches(&self, host: &str, port: u16) -> bool {
        let port_ok = match self.port {
            Some(p) => p == port,
            None => port == 80 || port == 443,
        };
        if !port_ok {
            return false;
        }
        if self.wildcard {
            host.len() > self.name.len() + 1
                && host.ends_with(&self.name)
                && host.as_bytes().get(host.len() - self.name.len() - 1) == Some(&b'.')
        } else {
            host == self.name
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(s: &str) -> Allowlist {
        Allowlist::parse(s).unwrap()
    }

    #[test]
    fn exact_match_is_case_insensitive_and_ignores_trailing_dot() {
        let l = list("api.anthropic.com");
        assert!(l.allows("api.anthropic.com", 443));
        assert!(l.allows("API.Anthropic.COM.", 443));
        assert!(l.allows("api.anthropic.com", 80));
        assert!(!l.allows("api.anthropic.com", 8443));
        assert!(!l.allows("anthropic.com", 443));
        assert!(!l.allows("evil-api.anthropic.com", 443));
        assert!(!l.allows("api.anthropic.com.evil.net", 443));
    }

    #[test]
    fn wildcard_matches_subdomains_only() {
        let l = list("*.github.com");
        assert!(l.allows("api.github.com", 443));
        assert!(l.allows("a.b.github.com", 443));
        assert!(
            !l.allows("github.com", 443),
            "bare suffix is not covered by *."
        );
        assert!(!l.allows("notgithub.com", 443));
        assert!(!l.allows("github.com.evil.net", 443));
    }

    #[test]
    fn explicit_port_restricts_to_the_two_redirected_ports() {
        let l = list("example.com:443");
        assert!(l.allows("example.com", 443));
        assert!(!l.allows("example.com", 80));
        assert!(Allowlist::parse("example.com:8443").is_err());
        assert!(Allowlist::parse("example.com:0").is_err());
    }

    #[test]
    fn separators_and_empty() {
        let l = list("a.com, b.com\n c.com\td.com");
        assert_eq!(l.len(), 4);
        assert!(list("").is_empty());
        assert!(!list("").allows("a.com", 443));
    }

    #[test]
    fn rejects_garbage() {
        for bad in [
            "*",
            "*.",
            "a.*.com",
            "*com",
            "-a.com",
            "a-.com",
            "a.com:0",
            "a.com:99999",
            "a.com:x",
            "a..com",
            ".a.com",
            "a.com..",
            "a.com:443:80",
        ] {
            assert!(Allowlist::parse(bad).is_err(), "{bad} should be rejected");
        }
    }

    #[test]
    fn invalid_query_hosts_are_never_allowed() {
        let l = list("*.com");
        assert!(!l.allows("", 443));
        assert!(!l.allows("a b.com", 443));
        assert!(!l.allows("x..com", 443));
    }
}
