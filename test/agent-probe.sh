#!/usr/bin/env bash
# Installed as pi in a test-only image. Exercises the real launcher/entrypoint
# without provider credentials or model calls, including startup self-update.
set -Eeuo pipefail
fail() { printf 'probe: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || fail 'agent/update ran as root'
for field in CapEff CapPrm CapInh CapAmb; do
    value="$(awk -v k="$field:" '$1 == k { print $2 }' /proc/self/status)"
    [[ "$value" == 0000000000000000 ]] || fail "$field was not zero: $value"
done
grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status || fail 'no-new-privileges missing'
if setpriv --reuid 0 true 2>/dev/null; then fail 'could regain root'; fi
if setpriv --reuid 65532 true 2>/dev/null; then fail 'could adopt the proxy uid'; fi
for trusted in /usr/local/bin/sapi-entrypoint /usr/bin/setpriv; do
    [[ ! -w "$trusted" ]] || fail "privileged setup is writable: $trusted"
done
if [[ "${1:-}" == update ]]; then
    [[ -w /opt/pi ]] || fail 'update prefix is not writable'
    printf 'probe: update unprivileged uid=%s\n' "$(id -u)" >&2
    exit 0
fi
printf 'probe\n' > /workspace/production-probe
if [[ "${*: -1}" == sapi-probe-network ]]; then
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://api.github.com/)" \
        || fail 'allowed TLS relay failed'
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || fail 'invalid upstream HTTP response'
    if curl -sS -m 8 https://example.com/ >/dev/null 2>&1; then fail 'denied hostname reachable'; fi
    if curl -ksS -m 8 https://1.1.1.1/ >/dev/null 2>&1; then fail 'raw-IP TLS reachable'; fi
    printf 'probe: network enforced\n'
fi
printf 'probe: identity protected uid=%s gid=%s\n' "$(id -u)" "$(id -g)"
