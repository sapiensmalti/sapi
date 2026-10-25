#!/usr/bin/env bash
# End-to-end smoke test. Requires Docker. Builds the real image and exercises
# the entrypoint non-interactively. Safe to run repeatedly; cleans up after itself.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

docker info >/dev/null 2>&1 || { echo "docker is not available" >&2; exit 1; }

export SAPI_IMAGE="sapi:smoke-test"
ws="$(mktemp -d)"
trap 'rm -rf "$ws"; docker image rm -f "$SAPI_IMAGE" >/dev/null 2>&1 || true' EXIT

echo "build"
if ./sapi build; then ok "image builds"; else bad "image builds"; exit 1; fi

harden=(--security-opt no-new-privileges --cap-drop ALL
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH --cap-add FOWNER
    --cap-add SETUID --cap-add SETGID --cap-add SETPCAP)
run() { docker run --rm --init "${harden[@]}" -e SAPI_AUTO_UPDATE=0 -v "$ws:/workspace" "$@"; }

echo "entrypoint"
out="$(run "$SAPI_IMAGE" --version 2>&1)" && ok "pi --version as root: $out" || bad "pi --version as root: $out"

uid="$(id -u)"; gid="$(id -g)"
[[ "$uid" == 0 ]] && { uid=1234; gid=1234; }   # CI often runs as root; still test the drop
out="$(docker run --rm --init "${harden[@]}" -e SAPI_AUTO_UPDATE=0 -e SAPI_UID="$uid" -e SAPI_GID="$gid" \
    -v "$ws:/workspace" --entrypoint /bin/bash "$SAPI_IMAGE" -c \
    'exec /usr/local/bin/sapi-entrypoint --version' 2>&1)" \
    && ok "pi --version as $uid:$gid: $out" || bad "pi --version as $uid:$gid: $out"

# Replace `pi` with `id` by exec-ing the entrypoint logic via a wrapper on PATH.
owner="$(docker run --rm --init "${harden[@]}" -e SAPI_AUTO_UPDATE=0 -e SAPI_UID="$uid" -e SAPI_GID="$gid" \
    -v "$ws:/workspace" --entrypoint /bin/bash "$SAPI_IMAGE" -c '
        mkdir -p /tmp/fake && printf "#!/bin/sh\ntouch /workspace/probe; id -u; id -g; echo \$HOME\n" > /tmp/fake/pi && chmod +x /tmp/fake/pi
        PATH=/tmp/fake:$PATH exec /usr/local/bin/sapi-entrypoint' 2>&1 | tr '\n' ' ')"
[[ "$owner" == "$uid $gid /home/sapi " ]] && ok "drops to $uid:$gid with HOME=/home/sapi" || bad "privilege drop: got '$owner'"

if [[ "$(uname -s)" == "Linux" ]]; then
    got="$(stat -c '%u:%g' "$ws/probe")"
    [[ "$got" == "$uid:$gid" ]] && ok "file in workspace owned by $uid:$gid" || bad "file ownership: $got"
else
    ok "file ownership check skipped (macOS maps ownership itself)"
fi

echo "tools in image"
for t in git rg jq curl uv node npm ssh; do
    run --entrypoint /bin/sh "$SAPI_IMAGE" -c "command -v $t" >/dev/null 2>&1 && ok "$t" || bad "$t"
done

echo "isolation"
run --entrypoint /bin/sh "$SAPI_IMAGE" -c 'test ! -e /var/run/docker.sock' && ok "no docker socket" || bad "docker socket present"
mounts="$(run --entrypoint /bin/sh "$SAPI_IMAGE" -c "awk '\$5 !~ /^\/(proc|sys|dev)/ {print \$5}' /proc/self/mountinfo | grep -v '^/$' | grep -v '^/etc/' | grep -v '^/workspace$' | grep -v '^/usr/sbin/docker-init$'" || true)"
[[ -z "$mounts" ]] && ok "only /workspace is mounted from outside" || bad "unexpected mounts: $mounts"
run --entrypoint /bin/sh "$SAPI_IMAGE" -c 'grep -q NoNewPrivs:.1 /proc/self/status' && ok "no-new-privileges" || bad "no-new-privileges"

echo "cli (docker-backed)"
./sapi ls >/dev/null && ok "sapi ls" || bad "sapi ls"
sapi_bin="$PWD/sapi"
(cd "$ws" && "$sapi_bin" rm >/dev/null 2>&1) && ok "sapi rm (nothing to remove)" || bad "sapi rm"

echo "toolchain (real build)"
pkg_img="sapi:smoke-pkg"
(cd "$(mktemp -d)" && SAPI_IMAGE="$pkg_img" SAPI_PACKAGES=file "$sapi_bin" build >/dev/null 2>&1) && ok "image builds with SAPI_PACKAGES" || bad "package build"
docker run --rm --entrypoint /usr/bin/file "$pkg_img" --version >/dev/null 2>&1 && ok "package is present in the image" || bad "package missing"
docker image rm -f "$pkg_img" >/dev/null 2>&1 || true

echo "egress allowlist (real firewall)"
# Build the sidecar from this checkout and prove the namespace firewall with a
# plain container that shares its network namespace. CI has internet.
if docker build -q -f egress/Dockerfile -t sapi-egress:smoke egress >/dev/null 2>&1; then ok "sidecar image builds"; else bad "sidecar image build"; fi
docker rm -f smoke-egress >/dev/null 2>&1 || true
docker run -d --name smoke-egress --init --security-opt no-new-privileges --cap-drop ALL \
    --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID --cap-add SETPCAP \
    -e EGRESS_ALLOW="api.github.com deb.debian.org" sapi-egress:smoke >/dev/null
for _ in $(seq 1 50); do docker exec smoke-egress test -f /run/egress/ready 2>/dev/null && break; sleep 0.2; done
docker exec smoke-egress test -f /run/egress/ready && ok "sidecar ready (firewall applied, privileges dropped)" || { bad "sidecar not ready"; docker logs smoke-egress; }
docker exec smoke-egress ps -o user,comm 2>/dev/null | grep -q 'egress .*sapi-egress' && ok "proxy runs as the unprivileged uid" || bad "proxy uid: $(docker exec smoke-egress ps -o user,comm)"
agent() { local ep="$1"; shift; docker run --rm --network container:smoke-egress --cap-drop ALL --security-opt no-new-privileges --entrypoint "$ep" "$SAPI_IMAGE" "$@"; }
# Allowed: HTTPS by SNI, relayed by name.
agent curl -fsS -m 20 -o /dev/null -w '%{http_code}' https://api.github.com/ 2>/dev/null | grep -q '^[23]' && ok "allowed https host reachable" || bad "allowed https host unreachable"
if (( fail > 0 )); then
    echo "--- diagnostics"
    echo "curl:"; agent curl -sS -m 10 -v https://api.github.com/ 2>&1 | tail -n 8 || true
    echo "getent:"; agent bash -c 'getent hosts api.github.com; cat /etc/resolv.conf' 2>&1 || true
    echo "iptables counters (filter):"; docker exec -u 0 smoke-egress iptables -L -v -n -x 2>&1 || true
    echo "iptables counters (nat):"; docker exec -u 0 smoke-egress iptables -t nat -L OUTPUT -v -n -x 2>&1 || true
    echo "direct udp to listener (bypassing nat):"; agent bash -c 'printf "\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x03api\\x06github\\x03com\\x00\\x00\\x01\\x00\\x01" > /dev/udp/127.0.0.1/15053; sleep 1' 2>&1 || true; docker logs smoke-egress 2>&1 | grep -c dns || true
    echo "direct tcp to tls listener:"; agent bash -c 'exec 3<>/dev/tcp/127.0.0.1/15443 && echo connected' 2>&1 || true
    echo "sysctls:"; docker exec -u 0 smoke-egress sh -c 'sysctl net.ipv4.conf.all.route_localnet net.ipv4.conf.lo.rp_filter net.ipv4.conf.all.rp_filter 2>&1' || true
    echo "nft ruleset:"; docker exec -u 0 smoke-egress sh -c 'apk add -q nftables >/dev/null 2>&1; nft list ruleset 2>&1 | head -n 60' || true
    echo "iptables backend:"; docker exec -u 0 smoke-egress iptables -V 2>&1 || true
    echo "listeners:"; docker exec -u 0 smoke-egress netstat -tulpn 2>&1 | head -n 10 || docker exec -u 0 smoke-egress cat /proc/net/tcp 2>&1 | head -n 5 || true
    echo "sidecar log:"; docker logs smoke-egress 2>&1 | tail -n 5
fi
# Allowed: plain HTTP by Host header.
agent curl -fsS -m 20 -o /dev/null -w '%{http_code}' http://deb.debian.org/debian/ 2>/dev/null | grep -q '^[23]' && ok "allowed http host reachable" || bad "allowed http host unreachable"
# Denied: name not in list → NXDOMAIN at the fake resolver.
agent curl -sS -m 10 https://example.com/ >/dev/null 2>&1 && bad "denied host was reachable!" || ok "denied host unreachable"
# Denied: allowed name, different port → dropped by policy.
agent bash -c 'timeout 5 bash -c "exec 3<>/dev/tcp/api.github.com/22"' >/dev/null 2>&1 && bad "non-80/443 port was open!" || ok "other ports dropped"
# Denied: raw IP with no name → connects to the filter, which has no SNI match... curl sends SNI only for names, so this is 'no hostname' → denied.
agent curl -sS -m 10 -k https://1.1.1.1/ >/dev/null 2>&1 && bad "raw IP egress possible!" || ok "raw IP egress blocked"
# The agent cannot change the rules (no NET_ADMIN).
docker run --rm --network container:smoke-egress --cap-drop ALL --security-opt no-new-privileges --entrypoint iptables sapi-egress:smoke -P OUTPUT ACCEPT >/dev/null 2>&1 && bad "a container without NET_ADMIN could alter the firewall!" || ok "the firewall cannot be altered without NET_ADMIN"
# Decisions are logged as JSON.
docker logs smoke-egress 2>/dev/null | grep -q '"ev":"deny"' && docker logs smoke-egress 2>/dev/null | grep -q '"ev":"allow","proto":"tls","host":"api.github.com"' && ok "allow and deny decisions logged" || { bad "egress log"; docker logs smoke-egress 2>&1 | tail -n 20; }
# Through the launcher: allowlist mode brings the sidecar up, runs, tears it down.
proj="$(mktemp -d)"
set +e
(cd "$proj" && SAPI_NETWORK=allowlist SAPI_ALLOW=@providers SAPI_MODEL=bogus/none SAPI_AUTO_UPDATE=0 SAPI_EGRESS_IMAGE=sapi-egress:smoke SAPI_IMAGE="$SAPI_IMAGE" "$sapi_bin" run "x" >/dev/null 2>/tmp/net.err)
set -e
grep -q "run: exit" /tmp/net.err && ok "sapi run in allowlist mode completes" || { bad "allowlist run"; cat /tmp/net.err; }
[[ -z "$(docker ps -aq --filter label=sh.sapi.egress-of)" ]] && ok "run sidecar removed afterwards" || bad "sidecar left behind"
rm -rf "$proj"
docker rm -f smoke-egress >/dev/null 2>&1; docker image rm -f sapi-egress:smoke >/dev/null 2>&1 || true

echo "sapi run (real container)"
proj="$(mktemp -d)"; echo hello >"$proj/a.txt"
set +e
out="$(cd "$proj" && SAPI_MODEL=bogus/none SAPI_AUTO_UPDATE=0 SAPI_IMAGE="$SAPI_IMAGE" "$sapi_bin" run "say hi" 2>/tmp/run.err)"; code=$?
set -e
[[ $code -ne 0 ]] && ok "run exits non-zero when pi fails (exit $code)" || bad "run should fail with a bogus model: $out"
grep -qi model <<<"$out$(cat /tmp/run.err)" && ok "pi error surfaced" || bad "no pi error: $out $(cat /tmp/run.err)"
[[ -z "$(docker ps -aq --filter label=sh.sapi.run=true)" ]] && ok "run container removed (--rm)" || bad "run container left behind"
set +e
(cd "$proj" && SAPI_MODEL=bogus/none SAPI_AUTO_UPDATE=0 SAPI_IMAGE="$SAPI_IMAGE" "$sapi_bin" --safer run "x" >/dev/null 2>&1)
set -e
m="$(ls "$HOME"/.local/share/sapi/backups/*/*.run 2>/dev/null | tail -1)"
[[ -n "$m" ]] && grep -q "^exit_code = [1-9]" "$m" && ok "--safer run wrote a manifest with the real exit code" || bad "run manifest: ${m:-none}"
(cd "$proj" && echo changed >a.txt && ! "$sapi_bin" diff >/dev/null 2>&1) && ok "diff sees the change after a real run" || bad "diff"
rm -rf "$proj" "$HOME/.local/share/sapi"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
