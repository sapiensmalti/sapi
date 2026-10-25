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
