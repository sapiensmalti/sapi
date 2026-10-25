//! A deliberately dumb DNS responder.
//!
//! The agent never performs a real DNS query. Every query the agent makes is
//! redirected here. Allowed names get a fixed, non-routable answer
//! (`198.18.0.1`, from the benchmarking range) so the client proceeds to
//! connect — and that connection is redirected to the TLS/HTTP filter, which
//! connects by *name*. Denied names get NXDOMAIN. The real resolution happens
//! in the relay, by the proxy, for allowed names only.
//!
//! This closes the DNS tunnelling channel and makes denials visible at the
//! earliest possible point.

use std::net::Ipv4Addr;

/// The answer returned for every allowed A query.
pub const SINK_ADDR: Ipv4Addr = Ipv4Addr::new(198, 18, 0, 1);
const TTL: u32 = 60;
const MAX_NAME: usize = 253;

/// A parsed question.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Question {
    /// Lower-case name without trailing dot.
    pub name: String,
    /// Query type (1 = A, 28 = AAAA, …).
    pub qtype: u16,
    /// Query class.
    pub qclass: u16,
}

/// Parse the first question of a DNS message. Returns `None` for anything
/// that is not a well-formed standard query with exactly one question.
pub fn parse_question(msg: &[u8]) -> Option<Question> {
    let flags = u16::from_be_bytes([*msg.get(2)?, *msg.get(3)?]);
    if flags & 0x8000 != 0 {
        return None; // a response, not a query
    }
    let qdcount = u16::from_be_bytes([*msg.get(4)?, *msg.get(5)?]);
    if qdcount != 1 {
        return None;
    }
    let mut pos = 12usize;
    let mut labels: Vec<String> = Vec::new();
    let mut total = 0usize;
    loop {
        let len = *msg.get(pos)? as usize;
        pos += 1;
        if len == 0 {
            break;
        }
        if len & 0xC0 != 0 {
            return None; // compression pointers are not valid in a question name
        }
        total += len + 1;
        if total > MAX_NAME {
            return None;
        }
        let label = msg.get(pos..pos + len)?;
        if !label
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_')
        {
            return None;
        }
        labels.push(String::from_utf8_lossy(label).to_ascii_lowercase());
        pos += len;
    }
    let qtype = u16::from_be_bytes([*msg.get(pos)?, *msg.get(pos + 1)?]);
    let qclass = u16::from_be_bytes([*msg.get(pos + 2)?, *msg.get(pos + 3)?]);
    Some(Question {
        name: labels.join("."),
        qtype,
        qclass,
    })
}

/// Build a response to `query`. `allowed` decides between an answer and
/// NXDOMAIN. The question section is echoed back verbatim.
pub fn build_response(query: &[u8], question: &Question, allowed: bool) -> Option<Vec<u8>> {
    // Length of the question section: name + 4.
    let mut qlen = 12usize;
    loop {
        let len = *query.get(qlen)? as usize;
        qlen += 1;
        if len == 0 {
            break;
        }
        qlen += len;
    }
    qlen += 4;
    let question_bytes = query.get(12..qlen)?;

    let id = query.get(0..2)?;
    let rd = query.get(2)? & 0x01;
    let mut out = Vec::with_capacity(qlen + 16);
    out.extend_from_slice(id);
    // QR=1, Opcode=0, AA=1, TC=0, RD=echo; RA=1, Z=0, RCODE
    let rcode: u8 = if allowed { 0 } else { 3 };
    out.push(0x84 | rd);
    out.push(0x80 | rcode);
    out.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    let answers: u16 = u16::from(allowed && question.qtype == 1 && question.qclass == 1);
    out.extend_from_slice(&answers.to_be_bytes()); // ANCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // NSCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // ARCOUNT
    out.extend_from_slice(question_bytes);
    if answers == 1 {
        out.extend_from_slice(&[0xC0, 0x0C]); // pointer to the question name
        out.extend_from_slice(&1u16.to_be_bytes()); // TYPE A
        out.extend_from_slice(&1u16.to_be_bytes()); // CLASS IN
        out.extend_from_slice(&TTL.to_be_bytes());
        out.extend_from_slice(&4u16.to_be_bytes());
        out.extend_from_slice(&SINK_ADDR.octets());
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query(name: &str, qtype: u16) -> Vec<u8> {
        let mut q = vec![0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
        for label in name.split('.') {
            q.push(u8::try_from(label.len()).unwrap());
            q.extend_from_slice(label.as_bytes());
        }
        q.push(0);
        q.extend_from_slice(&qtype.to_be_bytes());
        q.extend_from_slice(&1u16.to_be_bytes());
        q
    }

    #[test]
    fn parses_a_query() {
        let q = parse_question(&query("Api.GitHub.com", 1)).unwrap();
        assert_eq!(q.name, "api.github.com");
        assert_eq!(q.qtype, 1);
        assert_eq!(q.qclass, 1);
    }

    #[test]
    fn rejects_responses_multi_question_and_pointers() {
        let mut r = query("a.com", 1);
        if let Some(b) = r.get_mut(2) {
            *b |= 0x80;
        }
        assert!(parse_question(&r).is_none());
        let mut m = query("a.com", 1);
        if let Some(b) = m.get_mut(5) {
            *b = 2;
        }
        assert!(parse_question(&m).is_none());
        let mut p = query("a.com", 1);
        if let Some(b) = p.get_mut(12) {
            *b = 0xC0;
        }
        assert!(parse_question(&p).is_none());
        assert!(parse_question(&[0u8; 5]).is_none());
        assert!(parse_question(&[]).is_none());
    }

    #[test]
    fn allowed_a_gets_sink_address() {
        let q = query("api.github.com", 1);
        let question = parse_question(&q).unwrap();
        let r = build_response(&q, &question, true).unwrap();
        assert_eq!(r.get(0..2), Some(&[0x12, 0x34][..]));
        assert_eq!(r.get(3).map(|b| b & 0x0F), Some(0)); // NOERROR
        assert_eq!(r.get(6..8), Some(&[0, 1][..])); // one answer
        assert!(r.ends_with(&[198, 18, 0, 1]));
    }

    #[test]
    fn allowed_aaaa_gets_empty_noerror() {
        let q = query("api.github.com", 28);
        let question = parse_question(&q).unwrap();
        let r = build_response(&q, &question, true).unwrap();
        assert_eq!(r.get(3).map(|b| b & 0x0F), Some(0));
        assert_eq!(r.get(6..8), Some(&[0, 0][..]));
    }

    #[test]
    fn denied_gets_nxdomain() {
        let q = query("evil.example", 1);
        let question = parse_question(&q).unwrap();
        let r = build_response(&q, &question, false).unwrap();
        assert_eq!(r.get(3).map(|b| b & 0x0F), Some(3));
        assert_eq!(r.get(6..8), Some(&[0, 0][..]));
        assert_eq!(r.len(), q.len()); // header + echoed question, nothing else
    }
}
