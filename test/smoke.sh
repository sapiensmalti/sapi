#!/usr/bin/env bash
# Real Docker/entrypoint/firewall checks on Linux and macOS. Private fixtures;
# no provider credentials, model calls, Docker socket mounts, or fixed names.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }
docker info >/dev/null 2>&1 || { echo 'docker is not available' >&2; exit 1; }
TEST_ID="smoke-$$-$(date +%s)"
REAL_HOME="$HOME"; test_root="$(mktemp -d)"; test_root="$(cd "$test_root" && pwd -P)"
export DOCKER_CONFIG="${DOCKER_CONFIG:-$REAL_HOME/.docker}"
export HOME="$test_root/home"; mkdir -p "$HOME"
export SAPI_CONFIG_FILE="$HOME/config" SAPI_BACKUP_DIR="$HOME/backups"
export SAPI_CONFIG_VOLUME="$TEST_ID-config" SAPI_IMAGE="sapi:$TEST_ID"
EGRESS_CONTAINER="$TEST_ID-egress"; EGRESS_IMAGE="sapi-egress:$TEST_ID"
PKG_IMAGE="sapi:$TEST_ID-pkg"; PROBE_IMAGE="sapi:$TEST_ID-probe"
SHELL_CONFIG="$TEST_ID-shell-config"; SHELL_SESSIONS="$TEST_ID-shell-sessions"
unset SAPI_PACKAGES SAPI_DOCKERFILE_EXTRA SAPI_NETWORK SAPI_ALLOW SAPI_MODEL SAPI_REBUILD SAPI_AUTO_UPDATE
unset SAPI_DOCKER_ARGS SAPI_ENV SAPI_PI_VERSION SAPI_EGRESS_BUILD SAPI_EGRESS_IMAGE SAPI_UID SAPI_GID
ws="$test_root/workspace"; mkdir "$ws"
TEST_PROJECTS=""
cleanup() {
    local rc=$? p resource
    trap - EXIT
    set +e
    docker rm -f "$EGRESS_CONTAINER" >/dev/null 2>&1
    for p in $TEST_PROJECTS; do
        docker container ls -aq --filter "label=sh.sapi.workspace=$p" | while IFS= read -r resource; do docker rm -f "$resource" >/dev/null 2>&1; done
        docker volume ls -q --filter "label=sh.sapi.workspace=$p" | while IFS= read -r resource; do docker volume rm "$resource" >/dev/null 2>&1; done
    done
    docker volume rm "$SHELL_CONFIG" "$SHELL_SESSIONS" "$SAPI_CONFIG_VOLUME" >/dev/null 2>&1
    docker image rm -f "$PROBE_IMAGE" "$PKG_IMAGE" "$SAPI_IMAGE" "$EGRESS_IMAGE" >/dev/null 2>&1
    rm -rf -- "$test_root"
    exit "$rc"
}
trap cleanup EXIT

echo 'build'
if ./sapi build; then ok 'image builds'; else bad 'image builds'; exit 1; fi
harden=(--security-opt no-new-privileges --cap-drop ALL
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH --cap-add FOWNER
    --cap-add SETUID --cap-add SETGID)
run() { docker run --rm --init "${harden[@]}" -e SAPI_AUTO_UPDATE=0 -v "$ws:/workspace" "$@"; }
sapi_bin="$PWD/sapi"
uid="$(id -u)"; gid="$(id -g)"
if [[ "$uid" == 0 ]]; then
    uid=1234; gid=1234
    chown "$uid:$gid" "$ws" # Only this private fixture, never a user's project.
fi
export SAPI_UID="$uid" SAPI_GID="$gid"

echo 'entrypoint'
out="$(run "$SAPI_IMAGE" --version 2>&1)" && ok "pi --version with default non-root identity: $out" || bad "pi --version: $out"
if run -e SAPI_UID=0 "$SAPI_IMAGE" --version >/dev/null 2>&1; then bad 'image accepted uid 0'; else ok 'image refuses uid 0'; fi
out="$(run -e "SAPI_UID=$uid" -e "SAPI_GID=$gid" "$SAPI_IMAGE" --version 2>&1)" \
    && ok "pi --version as $uid:$gid" || bad "non-root pi: $out"
# Exercise host bind-mount writing and zero capabilities on both platforms.
owner="$(run -e "SAPI_UID=$uid" -e "SAPI_GID=$gid" --entrypoint /bin/bash "$SAPI_IMAGE" -c '
    mkdir -p /tmp/fake
    printf "#!/bin/sh\ntouch /workspace/probe; id -u; id -g; echo \$HOME; grep -E \"^Cap(Eff|Prm)\" /proc/self/status | tr \"\\t\" \" \" | cut -d\" \" -f2\n" > /tmp/fake/pi
    chmod +x /tmp/fake/pi
    PATH=/tmp/fake:$PATH exec /usr/local/bin/sapi-entrypoint' 2>&1 | tr '\n' ' ')"
[[ "$owner" == "$uid $gid /home/sapi 0000000000000000 0000000000000000 " ]] \
    && ok "drops to $uid:$gid, writes workspace, and has no capabilities" || bad "privilege drop: $owner"
if [[ "$(uname -s)" == Linux ]]; then
    got="$(stat -c '%u:%g' "$ws/probe")"
    [[ "$got" == "$uid:$gid" ]] && ok 'workspace file has the intended ownership' || bad "file ownership: $got"
else
    ok 'macOS workspace write verified; numeric host ownership is provider-mapped'
fi

echo 'image tools and isolation'
for tool in git rg jq curl uv node npm ssh; do
    run --entrypoint /bin/sh "$SAPI_IMAGE" -c "command -v $tool" >/dev/null 2>&1 && ok "$tool" || bad "$tool"
done
run --entrypoint /bin/sh "$SAPI_IMAGE" -c 'test ! -e /var/run/docker.sock' && ok 'no Docker socket' || bad 'Docker socket present'
mounts="$(run --entrypoint /bin/sh "$SAPI_IMAGE" -c "awk '\$5 !~ /^\\/(proc|sys|dev)/ {print \$5}' /proc/self/mountinfo | grep -v '^/$' | grep -v '^/etc/' | grep -v '^/workspace$' | grep -v '^/usr/sbin/docker-init$'" || true)"
[[ -z "$mounts" ]] && ok 'only workspace is bind-mounted' || bad "unexpected mounts: $mounts"
run --entrypoint /bin/sh "$SAPI_IMAGE" -c 'grep -q NoNewPrivs:.1 /proc/self/status' && ok 'no-new-privileges' || bad 'no-new-privileges'
./sapi ls >/dev/null && ok 'sapi ls' || bad 'sapi ls'
(cd "$ws" && "$sapi_bin" rm >/dev/null 2>&1) && ok 'sapi rm with nothing to remove' || bad 'empty cleanup'

echo 'custom toolchain'
mkdir "$test_root/pkg-project"
(cd "$test_root/pkg-project" && SAPI_IMAGE="$PKG_IMAGE" SAPI_PACKAGES=file "$sapi_bin" build >/dev/null 2>&1) \
    && ok 'image builds with custom packages' || bad 'custom package build'
docker run --rm --entrypoint /usr/bin/file "$PKG_IMAGE" --version >/dev/null 2>&1 && ok 'custom package is present' || bad 'custom package missing'

echo 'production identity and updater'
probe_ctx="$test_root/probe-image"; mkdir "$probe_ctx"
cp test/agent-probe.sh "$probe_ctx/probe.sh"
printf 'FROM %s\nRUN rm /opt/pi/bin/pi\nCOPY probe.sh /opt/pi/bin/pi\nRUN chmod 0755 /opt/pi/bin/pi\n' "$SAPI_IMAGE" >"$probe_ctx/Dockerfile"
if docker build -q -t "$PROBE_IMAGE" "$probe_ctx" >/dev/null; then ok 'test-only probe image builds'; else bad 'probe image build'; exit 1; fi
probe_project="$test_root/production-project"; mkdir "$probe_project"; TEST_PROJECTS+=" $probe_project"
if [[ "$(id -u)" == 0 ]]; then chown "$uid:$gid" "$probe_project"; fi
out="$(cd "$probe_project" && SAPI_IMAGE="$PROBE_IMAGE" SAPI_AUTO_UPDATE=1 "$sapi_bin" run sapi-probe-identity 2>"$test_root/probe.err")" \
    && ok 'production launcher prevents root/proxy-uid adoption with zero capabilities' || bad "production identity: $out $(cat "$test_root/probe.err")"
grep -q "probe: update unprivileged uid=$uid" "$test_root/probe.err" \
    && ok 'pi update also runs unprivileged with a writable npm prefix' || bad "updater: $(cat "$test_root/probe.err")"

echo 'egress allowlist'
if docker build -q -f egress/Dockerfile -t "$EGRESS_IMAGE" egress >/dev/null; then ok 'sidecar builds'; else bad 'sidecar build'; exit 1; fi
docker run -d --name "$EGRESS_CONTAINER" --init --read-only \
    --tmpfs '/run:rw,noexec,nosuid,nodev,size=1048576,mode=755' \
    --security-opt no-new-privileges --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
    -e EGRESS_ALLOW='api.github.com deb.debian.org' "$EGRESS_IMAGE" >/dev/null
for _ in $(seq 1 50); do docker exec "$EGRESS_CONTAINER" test -f /run/egress/ready 2>/dev/null && break; sleep 0.2; done
docker exec "$EGRESS_CONTAINER" test -f /run/egress/ready && ok 'sidecar ready' || { bad 'sidecar readiness'; docker logs "$EGRESS_CONTAINER"; }
docker exec "$EGRESS_CONTAINER" ps -o user,comm | grep -q 'egress .*sapi-egress' && ok 'unprivileged proxy' || bad 'proxy uid'
help="$(docker run --rm --entrypoint /usr/local/bin/sapi-egress "$EGRESS_IMAGE" --help)"
! grep -qE 'no-firewall|test-upstream|allow-private' <<<"$help" && ok 'no production bypass flags' || bad 'bypass flags exposed'
docker exec "$EGRESS_CONTAINER" touch /sapi-write-test >/dev/null 2>&1 && bad 'sidecar root writable' || ok 'sidecar root read-only'
docker restart "$EGRESS_CONTAINER" >/dev/null
for _ in $(seq 1 50); do docker exec "$EGRESS_CONTAINER" test -f /run/egress/ready 2>/dev/null && break; sleep 0.2; done
docker exec "$EGRESS_CONTAINER" test -f /run/egress/ready && ok 'restart ready' || bad 'restart readiness'
[[ "$(docker exec -u 0 "$EGRESS_CONTAINER" iptables -S | grep -c -- '-A OUTPUT -m owner --uid-owner 65532 -j ACCEPT')" == 1 ]] \
    && ok 'restart does not duplicate firewall rules' || bad 'duplicate firewall rules'
# Bare probes isolate the firewall; production-spec probes below also test
# the actual launcher, bootstrap capabilities, uid drop, and update path.
agent() { local ep="$1"; shift; docker run --rm --network container:"$EGRESS_CONTAINER" --cap-drop ALL --security-opt no-new-privileges --entrypoint "$ep" "$SAPI_IMAGE" "$@"; }
agent curl -sS -m 20 -o /dev/null -w '%{http_code}' https://api.github.com/ 2>/dev/null | grep -qE '^[1-5][0-9][0-9]$' \
    && ok 'allowed TLS upstream responds (including rate-limit HTTP status)' || bad 'allowed TLS unreachable'
agent curl -fsS -m 20 -o /dev/null -w '%{http_code}' http://deb.debian.org/debian/ 2>/dev/null | grep -q '^[23]' \
    && ok 'allowed HTTP reachable' || bad 'allowed HTTP unreachable'
agent curl -sS -m 10 https://example.com/ >/dev/null 2>&1 && bad 'denied host reachable' || ok 'denied host blocked'
agent bash -c 'timeout 5 bash -c "exec 3<>/dev/tcp/api.github.com/22"' >/dev/null 2>&1 && bad 'port 22 open' || ok 'other ports blocked'
agent curl -ksS -m 10 https://1.1.1.1/ >/dev/null 2>&1 && bad 'raw-IP TLS reachable' || ok 'raw-IP TLS blocked'
docker run --rm --network container:"$EGRESS_CONTAINER" --cap-drop ALL --security-opt no-new-privileges --entrypoint iptables "$EGRESS_IMAGE" -P OUTPUT ACCEPT >/dev/null 2>&1 \
    && bad 'firewall change permitted' || ok 'no NET_ADMIN means no firewall changes'
logged=0
for _ in $(seq 1 25); do
    if docker logs "$EGRESS_CONTAINER" 2>/dev/null | grep -q '"ev":"deny"' \
        && docker logs "$EGRESS_CONTAINER" 2>/dev/null | grep -q '"ev":"allow","proto":"tls","host":"api.github.com"'; then logged=1; break; fi
    sleep 0.2
done
[[ "$logged" == 1 ]] && ok 'allow/deny logs recorded' || bad 'egress logs missing'
out="$(cd "$probe_project" && SAPI_IMAGE="$PROBE_IMAGE" SAPI_NETWORK=allowlist SAPI_ALLOW='@providers @npm api.github.com' SAPI_AUTO_UPDATE=1 SAPI_EGRESS_IMAGE="$EGRESS_IMAGE" "$sapi_bin" run sapi-probe-network 2>"$test_root/network-probe.err")" \
    && ok 'production allowlist blocks uid adoption and denied traffic' || bad "production network: $out $(cat "$test_root/network-probe.err")"
grep -q 'probe: update unprivileged' "$test_root/network-probe.err" && ok 'allowlisted updater is unprivileged' || bad 'allowlisted updater'
[[ -z "$(docker ps -aq --filter "label=sh.sapi.egress-of" --filter "label=sh.sapi.workspace=$probe_project")" ]] \
    && ok 'headless sidecar removed' || bad 'headless sidecar leaked'
if (( fail > 0 )); then
    docker exec -u 0 "$EGRESS_CONTAINER" iptables -L -v -n -x || true
    docker exec -u 0 "$EGRESS_CONTAINER" iptables -t nat -L OUTPUT -v -n -x || true
    docker logs "$EGRESS_CONTAINER" 2>&1 | tail -n 20 || true
fi

echo 'shell'
out="$(docker run --rm --network none "${harden[@]}" \
    -v "$SHELL_CONFIG":/pi-config -v "$SHELL_SESSIONS":/pi-sessions \
    -e SAPI_CMD=bash -e SAPI_AUTO_UPDATE=1 -e "SAPI_UID=$uid" -e "SAPI_GID=$gid" \
    --workdir /pi-sessions "$SAPI_IMAGE" -c 'pwd; id -u; touch probe && stat -c %u probe' 2>&1)"
[[ "$(sed -n 1p <<<"$out")" == /pi-sessions ]] && ok 'shell cwd' || bad "shell cwd: $out"
[[ "$(sed -n 2p <<<"$out")" == "$uid" && "$(sed -n 3p <<<"$out")" == "$uid" ]] \
    && ok 'non-root shell writes sessions on this provider' || bad "shell uid: $out"

echo 'headless results and recovery'
proj="$test_root/run-project"; mkdir "$proj"; TEST_PROJECTS+=" $proj"; echo hello >"$proj/a.txt"
code=0
out="$(cd "$proj" && SAPI_MODEL=bogus/none SAPI_AUTO_UPDATE=0 "$sapi_bin" run 'say hi' 2>"$ws/run.err")" || code=$?
[[ "$code" != 0 ]] && ok 'pi failure propagates' || bad 'bogus model succeeded'
grep -qi model <<<"$out$(cat "$ws/run.err")" && ok 'model error surfaced' || bad "no model error: $out $(cat "$ws/run.err")"
[[ -z "$(docker ps -aq --filter 'label=sh.sapi.run=true')" ]] && ok 'run containers removed' || bad 'run container leaked'
(cd "$proj" && SAPI_MODEL=bogus/none SAPI_AUTO_UPDATE=0 "$sapi_bin" --safer run x >/dev/null 2>&1) || true
m="$(find "$SAPI_BACKUP_DIR" -name '*.run' -type f | sort | tail -n1)"
[[ -n "$m" ]] && grep -q '^exit_code = [1-9]' "$m" && ok 'safer run records its exit status' || bad 'run manifest missing'
(cd "$proj" && echo changed >a.txt && ! "$sapi_bin" diff >/dev/null 2>&1) && ok 'diff sees workspace change' || bad 'diff'
if (cd "$proj" && "$sapi_bin" rm); then ok 'cleanup completes'; else bad 'cleanup failed'; fi
[[ -z "$(docker volume ls -q --filter "label=sh.sapi.workspace=$proj" --filter 'label=sh.sapi.volume-role=sessions')" ]] \
    && ok 'session volumes removed' || bad 'session volumes leaked'
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
