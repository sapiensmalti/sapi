//! Extract the destination hostname from the first bytes of a connection:
//! the SNI of a TLS `ClientHello`, or the Host of an HTTP/1.x request.
//!
//! Both parsers are total: any malformed input yields `None`, never a panic
//! and never a guess. No hostname means the connection is denied.

/// Outcome of looking at the head of a stream.
#[derive(Debug, PartialEq, Eq)]
pub enum Sniff {
    /// A hostname was found.
    Host(String),
    /// The buffer is a valid prefix but more bytes are needed.
    Incomplete,
    /// This is not something we can route.
    Invalid,
}

fn be16(b: &[u8], at: usize) -> Option<usize> {
    Some(usize::from(u16::from_be_bytes([
        *b.get(at)?,
        *b.get(at + 1)?,
    ])))
}

/// TLS `ClientHello` → SNI host name.
pub fn tls_sni(buf: &[u8]) -> Sniff {
    // TLS record: type(1)=0x16, version(2), length(2)
    let Some(&rec_type) = buf.first() else {
        return Sniff::Incomplete;
    };
    if rec_type != 0x16 {
        return Sniff::Invalid;
    }
    let Some(rec_len) = be16(buf, 3) else {
        return Sniff::Incomplete;
    };
    if rec_len == 0 || rec_len > 16_384 {
        return Sniff::Invalid;
    }
    if buf.len() < 5 + rec_len {
        return Sniff::Incomplete;
    }
    let Some(hs) = buf.get(5..5 + rec_len) else {
        return Sniff::Incomplete;
    };
    // Handshake: type(1)=1, length(3), version(2), random(32), session_id
    if hs.first() != Some(&1) {
        return Sniff::Invalid;
    }
    let mut p = 4 + 2 + 32;
    let Some(&sid_len) = hs.get(p) else {
        return Sniff::Invalid;
    };
    p += 1 + usize::from(sid_len);
    let Some(cs_len) = be16(hs, p) else {
        return Sniff::Invalid;
    };
    p += 2 + cs_len;
    let Some(&comp_len) = hs.get(p) else {
        return Sniff::Invalid;
    };
    p += 1 + usize::from(comp_len);
    let Some(ext_total) = be16(hs, p) else {
        return Sniff::Invalid;
    };
    p += 2;
    let Some(exts) = hs.get(p..p + ext_total) else {
        return Sniff::Invalid;
    };
    let mut q = 0;
    while q + 4 <= exts.len() {
        let (Some(ext_type), Some(ext_len)) = (be16(exts, q), be16(exts, q + 2)) else {
            return Sniff::Invalid;
        };
        q += 4;
        let Some(ext) = exts.get(q..q + ext_len) else {
            return Sniff::Invalid;
        };
        if ext_type == 0 {
            // server_name: list_len(2), then entries: type(1)=0, len(2), name
            let Some(list_len) = be16(ext, 0) else {
                return Sniff::Invalid;
            };
            let Some(list) = ext.get(2..2 + list_len) else {
                return Sniff::Invalid;
            };
            let mut r = 0;
            while r + 3 <= list.len() {
                let name_type = list.get(r).copied();
                let Some(name_len) = be16(list, r + 1) else {
                    return Sniff::Invalid;
                };
                let Some(name) = list.get(r + 3..r + 3 + name_len) else {
                    return Sniff::Invalid;
                };
                if name_type == Some(0) {
                    return match std::str::from_utf8(name) {
                        Ok(s) if !s.is_empty() && s.is_ascii() => Sniff::Host(s.to_owned()),
                        _ => Sniff::Invalid,
                    };
                }
                r += 3 + name_len;
            }
            return Sniff::Invalid;
        }
        q += ext_len;
    }
    Sniff::Invalid // complete ClientHello without SNI: cannot route by name
}

/// HTTP/1.x request head → Host (without port).
pub fn http_host(buf: &[u8]) -> Sniff {
    let Some(end) = find(buf, b"\r\n\r\n") else {
        if buf.len() > 16_384 {
            return Sniff::Invalid;
        }
        // Reject early if the first line is clearly not HTTP.
        if let Some(nl) = find(buf, b"\r\n") {
            if !looks_like_request_line(buf.get(..nl).unwrap_or_default()) {
                return Sniff::Invalid;
            }
        }
        return Sniff::Incomplete;
    };
    let Ok(head) = std::str::from_utf8(buf.get(..end).unwrap_or_default()) else {
        return Sniff::Invalid;
    };
    let mut lines = head.split("\r\n");
    let Some(request_line) = lines.next() else {
        return Sniff::Invalid;
    };
    if !looks_like_request_line(request_line.as_bytes()) {
        return Sniff::Invalid;
    }
    // Absolute-form target wins over Host (RFC 9112 §3.2.2).
    let target = request_line.split(' ').nth(1).unwrap_or("");
    if let Some(rest) = target.strip_prefix("http://") {
        let authority = rest.split('/').next().unwrap_or("");
        return host_without_port(authority);
    }
    let mut host: Option<&str> = None;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            if k.trim().eq_ignore_ascii_case("host") {
                if host.is_some() {
                    return Sniff::Invalid; // duplicate Host headers are a smuggling vector
                }
                host = Some(v.trim());
            }
        }
    }
    match host {
        Some(h) => host_without_port(h),
        None => Sniff::Invalid,
    }
}

fn host_without_port(authority: &str) -> Sniff {
    if authority.starts_with('[') {
        return Sniff::Invalid; // IPv6 literals are not names; we route by name only
    }
    let host = authority.split(':').next().unwrap_or("");
    if host.is_empty() {
        return Sniff::Invalid;
    }
    Sniff::Host(host.to_owned())
}

fn looks_like_request_line(line: &[u8]) -> bool {
    const METHODS: [&[u8]; 9] = [
        b"GET ",
        b"POST ",
        b"PUT ",
        b"HEAD ",
        b"DELETE ",
        b"PATCH ",
        b"OPTIONS ",
        b"TRACE ",
        b"CONNECT ",
    ];
    METHODS.iter().any(|m| line.starts_with(m)) || METHODS.iter().any(|m| m.starts_with(line))
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal `ClientHello` carrying the given SNI (or none).
    pub fn client_hello(sni: Option<&str>) -> Vec<u8> {
        let mut exts = Vec::new();
        if let Some(name) = sni {
            let n = name.as_bytes();
            let mut sni_ext = Vec::new();
            sni_ext.extend_from_slice(&u16::try_from(n.len() + 3).unwrap().to_be_bytes());
            sni_ext.push(0);
            sni_ext.extend_from_slice(&u16::try_from(n.len()).unwrap().to_be_bytes());
            sni_ext.extend_from_slice(n);
            exts.extend_from_slice(&0u16.to_be_bytes());
            exts.extend_from_slice(&u16::try_from(sni_ext.len()).unwrap().to_be_bytes());
            exts.extend_from_slice(&sni_ext);
        }
        // another extension (supported_versions) to make sure we skip correctly
        exts.extend_from_slice(&[0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04]);
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]); // version
        body.extend_from_slice(&[0u8; 32]); // random
        body.push(0); // session id len
        body.extend_from_slice(&[0x00, 0x02, 0x13, 0x01]); // one cipher suite
        body.extend_from_slice(&[0x01, 0x00]); // compression
        body.extend_from_slice(&u16::try_from(exts.len()).unwrap().to_be_bytes());
        body.extend_from_slice(&exts);
        let mut hs = vec![0x01];
        let len = u32::try_from(body.len()).unwrap().to_be_bytes();
        hs.extend_from_slice(&len[1..]);
        hs.extend_from_slice(&body);
        let mut rec = vec![0x16, 0x03, 0x01];
        rec.extend_from_slice(&u16::try_from(hs.len()).unwrap().to_be_bytes());
        rec.extend_from_slice(&hs);
        rec
    }

    #[test]
    fn extracts_sni() {
        assert_eq!(
            tls_sni(&client_hello(Some("api.anthropic.com"))),
            Sniff::Host("api.anthropic.com".into())
        );
    }

    #[test]
    fn incomplete_then_complete() {
        let full = client_hello(Some("x.example"));
        for cut in [0, 1, 4, 5, 20, full.len() - 1] {
            assert_eq!(
                tls_sni(full.get(..cut).unwrap()),
                Sniff::Incomplete,
                "cut at {cut}"
            );
        }
        assert_eq!(tls_sni(&full), Sniff::Host("x.example".into()));
    }

    #[test]
    fn no_sni_is_invalid() {
        assert_eq!(tls_sni(&client_hello(None)), Sniff::Invalid);
    }

    #[test]
    fn non_tls_is_invalid() {
        assert_eq!(tls_sni(b"GET / HTTP/1.1\r\n"), Sniff::Invalid);
        assert_eq!(
            tls_sni(&[0x16, 0x03, 0x01, 0xff, 0xff, 0x01]),
            Sniff::Invalid
        );
        assert_eq!(tls_sni(&[0x16, 0x03, 0x01, 0x00, 0x00]), Sniff::Invalid);
    }

    #[test]
    fn truncated_lengths_do_not_panic() {
        let full = client_hello(Some("a.b"));
        // Corrupt every byte in turn; must return without panicking.
        for i in 0..full.len() {
            let mut c = full.clone();
            if let Some(b) = c.get_mut(i) {
                *b = 0xff;
            }
            let _ = tls_sni(&c);
        }
    }

    #[test]
    fn http_host_header() {
        assert_eq!(
            http_host(b"GET /x HTTP/1.1\r\nHost: deb.debian.org\r\nUser-Agent: apt\r\n\r\n"),
            Sniff::Host("deb.debian.org".into())
        );
        assert_eq!(
            http_host(b"GET /x HTTP/1.1\r\nhost: Example.com:8080\r\n\r\n"),
            Sniff::Host("Example.com".into())
        );
    }

    #[test]
    fn http_absolute_form_wins() {
        assert_eq!(
            http_host(b"GET http://a.example/p HTTP/1.1\r\nHost: b.example\r\n\r\n"),
            Sniff::Host("a.example".into())
        );
    }

    #[test]
    fn http_rejects_duplicate_host_missing_host_and_non_http() {
        assert_eq!(
            http_host(b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
            Sniff::Invalid
        );
        assert_eq!(http_host(b"GET / HTTP/1.1\r\nX: y\r\n\r\n"), Sniff::Invalid);
        assert_eq!(http_host(b"SSH-2.0-OpenSSH\r\n"), Sniff::Invalid);
        assert_eq!(
            http_host(b"GET / HTTP/1.1\r\nHost: [::1]\r\n\r\n"),
            Sniff::Invalid
        );
        assert_eq!(http_host(b"GET / HT"), Sniff::Incomplete);
        assert_eq!(
            http_host(b"GET / HTTP/1.1\r\nHost: a.com\r\n"),
            Sniff::Incomplete
        );
    }
}
