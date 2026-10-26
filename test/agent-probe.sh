#!/usr/bin/env bash
# Test-only pi replacement. Exercise the real root launcher/entrypoint without
# provider credentials/model calls, including updates and deliberate uid changes.
set -Eeuo pipefail
fail() { printf 'probe: %s\n' "$*" >&2; exit 1; }
for flag in -u -ru -g -rg; do
    [[ "$(id "$flag")" == 0 ]] || fail 'agent/update was not root (0:0)'
done
[[ "$HOME:$USER" == /root:root ]] || fail 'root environment was not set'
grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status || fail 'no-new-privileges missing'
caps="$(awk '$1 == "CapEff:" {print $2}' /proc/self/status)"
(( (16#$caps & 0xc0) == 0xc0 )) || fail 'container root lost identity-changing capabilities'
(( (16#$caps & 0x203000) == 0 )) || fail 'agent received network/admin escape capabilities'
[[ ! -w /sys/fs/cgroup/cgroup.procs ]] || fail 'agent can change cgroup membership'
# Root is genuinely root: it may deliberately run a child under another uid.
[[ "$(setpriv --reuid 65532 --regid 65532 --clear-groups id -u)" == 65532 ]] || fail 'root could not change a child uid'
[[ "$(id -u)" == 0 ]] || fail 'parent agent identity changed'
if [[ "${1:-}" == update ]]; then
    [[ -w /opt/pi ]] || fail 'npm prefix is not writable by root'
    printf 'probe: update root uid=0 gid=0\n' >&2
    exit 0
fi
printf 'probe\n' > /workspace/production-probe
if [[ "${*: -1}" == sapi-probe-network ]]; then
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://api.github.com/)" || fail 'allowed TLS relay failed'
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || fail 'invalid upstream HTTP response'
    # The old UID exemption would allow the proxy-uid case to escape. Every
    # child remains in the agent cgroup, regardless of its Unix credentials.
    for uid in 0 1234 65532; do
        if setpriv --reuid "$uid" --regid "$uid" --clear-groups curl -sS -m 8 https://example.com/ >/dev/null 2>&1; then
            fail "uid $uid escaped the cgroup allowlist"
        fi
    done
    if curl -ksS -m 8 https://1.1.1.1/ >/dev/null 2>&1; then fail 'raw-IP TLS reachable'; fi
    printf 'probe: network enforced across uid changes\n'
fi
printf 'probe: agent root uid=0 gid=0\n'
