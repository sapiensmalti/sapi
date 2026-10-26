#!/usr/bin/env bash
# Fail-closed settings and identity regressions. No Docker or network required.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
S="$PWD/sapi"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" SAPI_CONFIG_FILE="$tmp/config" SAPI_BACKUP_DIR="$tmp/backups"
export SAPI_UID=1234 SAPI_GID=1234
unset SAPI_DOCKER_ARGS SAPI_ENV SAPI_IMAGE SAPI_NETWORK SAPI_ALLOW SAPI_SAFER
mkdir -p "$HOME" "$tmp/bin" "$tmp/work"
export CALLS="$tmp/calls"
cat >"$tmp/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$CALLS"
case "$1" in run) printf 'agent started\n' ;; esac
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
# Reject root (including zero-padded spellings) before making any Docker call.
for uid in 0 00 0000000000 4294967295 99999999999; do
    SAPI_UID="$uid" call run test
    check "uid $uid is refused" test "$rc" -eq 1
    check "uid $uid fails before Docker is touched" test ! -s "$CALLS"
done
SAPI_UID=0000065532 SAPI_NETWORK=allowlist call run test
check "zero-padded proxy uid is refused" test "$rc" -eq 1
check "proxy uid is rejected before Docker is touched" test ! -s "$CALLS"
SAPI_UID=001234 SAPI_GID=001234 call run test
check "valid zero-padded identities remain usable" test "$rc" -eq 0
# Exercise macOS identity selection without requiring a VM. Host identity,
# rather than uid 0, must be used by default on every supported platform.
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
check "macOS default can start with the host identity" test "$rc" -eq 0
check "macOS passes the host uid" grep -qx 'SAPI_UID=501' "$CALLS.args"
check "macOS passes the host gid" grep -qx 'SAPI_GID=20' "$CALLS.args"
printf '\n%d safety checks passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
