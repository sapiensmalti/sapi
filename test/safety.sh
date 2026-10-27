#!/usr/bin/env bash
# Fail-closed settings and identity regressions. No Docker or network required.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
S="$PWD/sapi"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" SAPI_CONFIG_FILE="$tmp/config" SAPI_BACKUP_DIR="$tmp/backups"
export SAPI_UID=0 SAPI_GID=0 SAPI_BUILD=1
unset SAPI_DOCKER_ARGS SAPI_ENV SAPI_IMAGE SAPI_NETWORK SAPI_ALLOW SAPI_SAFER
mkdir -p "$HOME" "$tmp/bin" "$tmp/work"
export CALLS="$tmp/calls"
cat >"$tmp/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$CALLS"
case "$1" in run) printf '%s\n' "$@" >"$CALLS.args"; printf 'agent started\n' ;; esac
exit 0
SHIM
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
pass=0; fail=0
check() {
    local message="$1"; shift
    if "$@"; then pass=$((pass + 1)); printf '  ok   %s\n' "$message"
    else fail=$((fail + 1)); printf '  FAIL %s\n' "$message" >&2; fi
}
call() {
    : >"$CALLS"; rc=0
    (cd "$tmp/work" && "$S" "$@") >"$tmp/out" 2>"$tmp/err" || rc=$?
}
# Every persistent environment type must propagate a failed validation before
# configuration output, a build, a volume creation, or an agent launch.
printf 'safer = true\n' >"$SAPI_CONFIG_FILE"
for entry in 'SAPI_SAFER=typo' 'SAPI_BACKUP_DIR=relative' 'SAPI_BACKUP_KEEP=-1' \
    'SAPI_CPUS=no' 'SAPI_MEMORY_MIB=1.5' 'SAPI_PIDS=no' 'SAPI_PACKAGES=x;y' \
    'SAPI_DOCKERFILE_EXTRA=relative' 'SAPI_NETWORK=typo' 'SAPI_ALLOW=@missing'; do
    name="${entry%%=*}"; value="${entry#*=}"
    export "$name=$value"
    call config show
    check "$name invalid value returns 1" test "$rc" -eq 1
    check "$name diagnostic identifies its source" grep -Fq "$name" "$tmp/err"
    call run test
    check "$name cannot start an agent" test "$rc" -eq 1
    check "$name fails before Docker is touched" test ! -s "$CALLS"
    unset "$name"
done
# Blank list values are meaningful config entries, not missing values.
printf 'safer = true\nallow =\npackages =\n' >"$SAPI_CONFIG_FILE"
call config show
check "empty configured allow is preserved" grep -Eq '^allow[[:space:]]+\(config\)$' "$tmp/out"
check "empty configured packages is preserved" grep -Eq '^packages[[:space:]]+\(config\)$' "$tmp/out"
SAPI_SAFER=typo call --safer config show
check "an explicit safer flag takes precedence over its environment override" test "$rc" -eq 0
check "the flag enables safer mode" grep -Eq '^safer[[:space:]]+true[[:space:]]+\(flag\)$' "$tmp/out"
printf 'safer = typo\n' >"$SAPI_CONFIG_FILE"
call diff
check "early diff config failure returns 2, never the differences status" test "$rc" -eq 2
check "early diff config failure prints no change list" test ! -s "$tmp/out"
SAPI_UID=not-a-uid call diff
check "diff startup identity errors also return 2" test "$rc" -eq 2
SAPI_AUTO_UPDATE=invalid call diff
check "diff startup option errors also return 2" test "$rc" -eq 2
printf 'safer = false\n' >"$SAPI_CONFIG_FILE"
# No caller may select a non-root identity, including zero-padded aliases.
for uid in 1 1234 0000065532 4294967295 99999999999; do
    SAPI_UID="$uid" call run test
    check "uid $uid is refused" test "$rc" -eq 1
    check "uid $uid fails before Docker is touched" test ! -s "$CALLS"
done
SAPI_GID=1234 call run test
check "a non-root group is refused" test "$rc" -eq 1
check "non-root group fails before Docker is touched" test ! -s "$CALLS"
for uid in 0 00 0000000000; do
    SAPI_UID="$uid" SAPI_GID="$uid" call run test
    check "root spelling $uid is accepted" test "$rc" -eq 0
done
SAPI_DOCKER_ARGS='--user 1234:1234 --cgroupns host --entrypoint /bin/false --env SAPI_UID=1234' call run test
check "extra Docker flags cannot change the root launch identity" test "$(awk '$0 == "--user" {getline; value=$0} END {print value}' "$CALLS.args")" = 0:0
check "extra Docker flags cannot share the proxy cgroup namespace" test "$(awk '$0 == "--cgroupns" {getline; value=$0} END {print value}' "$CALLS.args")" = private
check "extra Docker flags cannot replace the root-checking entrypoint" test "$(awk '$0 == "--entrypoint" {getline; value=$0} END {print value}' "$CALLS.args")" = /usr/local/bin/sapi-entrypoint
check "extra environment cannot request a non-root uid" test "$(awk '$0 == "--env" {getline; if ($0 ~ /^SAPI_UID=/) value=$0} END {print value}' "$CALLS.args")" = SAPI_UID=0
# Exercise the actual entrypoint locally without any pi execution, filesystem
# changes, credentials, or network. Root containers also run this in Debian CI.
"$S" dockerfile | awk "/^COPY <<'ENTRYPOINT_EOF'/ {printing=1; next} /^ENTRYPOINT_EOF$/ {printing=0} printing" >"$tmp/entrypoint"
rc=0
SAPI_CMD=/usr/bin/id SAPI_AUTO_UPDATE=0 bash "$tmp/entrypoint" -u >"$tmp/entry.out" 2>"$tmp/entry.err" || rc=$?
if [[ "$(id -u):$(id -g)" == 0:0 ]]; then
    check "actual root entrypoint succeeds without dropping identity" test "$rc" -eq 0
    check "entrypoint-launched command observes uid 0" grep -qx 0 "$tmp/entry.out"
else
    check "actual non-root entrypoint is refused" test "$rc" -eq 1
    check "non-root guard reports actual credential failure" grep -q 'actual root credentials' "$tmp/entry.err"
fi
printf 'USER 1234:1234\n' >"$tmp/override.df"
SAPI_DOCKERFILE_EXTRA="$tmp/override.df" "$S" dockerfile >"$tmp/custom.df"
check "user fragment cannot change the final image user" test "$(tail -n1 "$tmp/custom.df")" = 'USER 0:0'
# Host identity must never change the root identity on either platform.
cat >"$tmp/bin/uname" <<'SHIM'
#!/bin/sh
printf 'Darwin\n'
SHIM
cat >"$tmp/bin/id" <<'SHIM'
#!/bin/sh
case "$1" in -u) echo 501 ;; -g) echo 20 ;; *) exit 1 ;; esac
SHIM
chmod +x "$tmp/bin/uname" "$tmp/bin/id"
# Record only the safe, fixed identity arguments, not passed environment data.
cat >"$tmp/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$CALLS"
case "$1" in run) printf '%s\n' "$@" >"$CALLS.args" ;; esac
exit 0
SHIM
rc=0
(cd "$tmp/work" && env -u SAPI_UID -u SAPI_GID "$S" run test) >"$tmp/out" 2>"$tmp/err" || rc=$?
check "macOS non-root caller starts a root agent" test "$rc" -eq 0
check "macOS passes root uid, not the host uid" grep -qx 'SAPI_UID=0' "$CALLS.args"
check "macOS passes root gid, not the host gid" grep -qx 'SAPI_GID=0' "$CALLS.args"
printf '#!/bin/sh\nprintf "Linux\\n"\n' >"$tmp/bin/uname"
rc=0
(cd "$tmp/work" && env -u SAPI_UID -u SAPI_GID "$S" run test) >"$tmp/out" 2>"$tmp/err" || rc=$?
check "Linux non-root caller starts a root agent" test "$rc" -eq 0
check "Linux forces the Docker user to root" test "$(awk '$0 == "--user" {getline; value=$0} END {print value}' "$CALLS.args")" = 0:0
printf '\n%d safety checks passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
