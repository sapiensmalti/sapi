#!/usr/bin/env bash
# Recovery regressions: real archives and deterministic host-command failures.
# No Docker, credentials, network, or writes outside this private fixture tree.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
S="$PWD/sapi"
real_mv="$(command -v mv)"
real_mkdir="$(command -v mkdir)"
real_cat="$(command -v cat)"
real_readlink="$(command -v readlink)"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
writer=""
cleanup() {
    if [[ -n "$writer" ]]; then
        kill "$writer" 2>/dev/null || true
        wait "$writer" 2>/dev/null || true
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
export HOME="$tmp/home" SAPI_CONFIG_FILE="$tmp/config" SAPI_BACKUP_DIR="$tmp/backups" TMPDIR="$tmp/tmp"
mkdir -p "$HOME" "$TMPDIR" "$tmp/shim"
pass=0; fail=0
check() {
    local message="$1"; shift
    if "$@"; then
        pass=$((pass + 1)); printf '  ok   %s\n' "$message"
    else
        fail=$((fail + 1)); printf '  FAIL %s\n' "$message" >&2
    fi
}
new_workspace() {
    work="$tmp/$1/work"
    mkdir -p "$work"
}
run_sapi() {
    rc=0
    (cd "$work" && "$S" "$@") >"$tmp/out" 2>"$tmp/err" || rc=$?
}
snapshot() {
    run_sapi backup
    [[ "$rc" == 0 ]] || { cat "$tmp/err" >&2; exit 1; }
    backup="$(<"$tmp/out")"
}
saved_link_target_is() {
    [[ -L "$saved" ]] && [[ "$(readlink "$saved")" == "$1" ]]
}
wait_for() {
    local i
    for ((i=0; i<100; i++)); do
        [[ -e "$1" ]] && return 0
        sleep 0.05
    done
    printf 'timed out waiting for %s\n' "$1" >&2
    return 1
}

# An empty first awk input must not make current paths look deleted.
new_workspace empty
snapshot
run_sapi diff "$backup"
check "two empty trees compare equal" test "$rc" -eq 0
printf 'new\n' >"$work/new"
run_sapi diff "$backup"
check "empty backup reports an addition, not a deletion" grep -qx 'A  new' "$tmp/out"
check "changes exit exactly 1" test "$rc" -eq 1
run_sapi diff "$backup" --full
check "full diff from empty backup includes new contents" grep -qx '+new' "$tmp/out"
snapshot
rm "$work/new"
run_sapi diff "$backup"
check "empty current tree reports deletion" grep -qx 'D  new' "$tmp/out"

# Command substitution must not discard newlines in a symlink target.
new_workspace links
ln -s target "$work/link"
snapshot
rm "$work/link"; ln -s $'target\n' "$work/link"
run_sapi diff "$backup"
check "diff detects a trailing-newline symlink retarget" grep -qx 'M  link' "$tmp/out"
# BSD readlink adds a newline only if the target does not already end with
# one. Reproduce that behavior on Linux too; -n must return the exact bytes.
cat >"$tmp/shim/readlink" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == -n ]]; then exec "$REAL_READLINK" "$@"; fi
target="$("$REAL_READLINK" -n "$@" && printf .)" || exit 1
target="${target%.}"
printf '%s' "$target"
if [[ "$target" != *$'\n' ]]; then printf '\n'; fi
SHIM
chmod +x "$tmp/shim/readlink"
export REAL_READLINK="$real_readlink"
PATH="$tmp/shim:$PATH" run_sapi diff "$backup"
check "diff preserves target newlines with BSD readlink semantics" grep -qx 'M  link' "$tmp/out"
rm "$tmp/shim/readlink"
snapshot
run_sapi diff "$backup"
check "unchanged newline symlink compares equal" test "$rc" -eq 0
rm "$work/link"; ln -s $'target\n\n' "$work/link"
run_sapi diff "$backup"
check "diff distinguishes one and two trailing newlines" grep -qx 'M  link' "$tmp/out"

# Fatal errors must not be mistaken for detected changes by automation.
run_sapi diff "$tmp/missing.tar.gz"
check "missing backup exits exactly 2" test "$rc" -eq 2
run_sapi diff --unknown
check "invalid diff option exits exactly 2" test "$rc" -eq 2
printf 'not an archive\n' >"$tmp/corrupt.tar.gz"
run_sapi diff "$tmp/corrupt.tar.gz"
check "archive extraction failure exits exactly 2" test "$rc" -eq 2
cp "$backup" "$tmp/checksummed.tar.gz"
printf '%064d  archive\n' 0 >"$tmp/checksummed.tar.gz.sha256"
run_sapi diff "$tmp/checksummed.tar.gz"
check "checksum mismatch exits exactly 2" test "$rc" -eq 2
printf '#!/bin/sh\nexit 1\n' >"$tmp/shim/sort"; chmod +x "$tmp/shim/sort"
PATH="$tmp/shim:$PATH" run_sapi diff "$backup"
check "an unhandled command failure exits exactly 2" test "$rc" -eq 2
check "a failed diff cleans its private staging" test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
printf '#!/bin/sh\nkill -TERM "$PPID"\nexit 0\n' >"$tmp/shim/sort"
PATH="$tmp/shim:$PATH" run_sapi diff "$backup"
check "diff retains signal status 143 rather than mapping it to 2" test "$rc" -eq 143
check "an interrupted diff cleans its private staging" test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
rm "$tmp/shim/sort"
printf '#!/bin/sh\nexit 1\n' >"$tmp/shim/readlink"; chmod +x "$tmp/shim/readlink"
PATH="$tmp/shim:$PATH" run_sapi diff "$backup"
check "a failed readlink is an error, not a symlink change" test "$rc" -eq 2
rm "$tmp/shim/readlink"
printf '#!/bin/sh\nexit 2\n' >"$tmp/shim/diff"; chmod +x "$tmp/shim/diff"
# Use a regular file so --full actually invokes diff(1).
printf 'before\n' >"$work/file"; snapshot; printf 'after\n' >"$work/file"
PATH="$tmp/shim:$PATH" run_sapi diff "$backup" --full
check "a failed hunk comparison exits exactly 2" test "$rc" -eq 2
rm "$tmp/shim/diff"

# Path bytes must survive --full decoding and selective restore unchanged.
new_workspace names
mkdir "$work/dir"
printf 'before\n' >"$work/dir/line"$'\n'
printf 'before\n' >"$work/dir/line"$'\t'
snapshot
printf 'after\n' >"$work/dir/line"$'\n'
printf 'after\n' >"$work/dir/line"$'\t'
run_sapi diff "$backup" --full
check "full diff handles newline and tab filenames" test "$(grep -c '^+after$' "$tmp/out")" -eq 2
run_sapi restore "$backup" --files $'dir/line\n' $'dir/line\t'
check "selective restore accepts newline and tab filenames" test "$rc" -eq 0
check "selective restore preserves filename bytes" test "$(<"$work/dir/line"$'\n')" = before
check "selective restore also restores the second selection" test "$(<"$work/dir/line"$'\t')" = before
mkdir "$work/parent"$'\n'"name"
printf 'nested\n' >"$work/parent"$'\n'"name/file"
snapshot
rm -r "$work/parent"$'\n'"name"
run_sapi restore "$backup" --files $'parent\nname/file'
check "selective restore handles a newline in a missing parent" test "$rc" -eq 0
check "selective restore creates no truncated parent" test ! -e "$work/parent"
check "the restored nested path has its original bytes" grep -qx nested "$work/parent"$'\n'"name/file"
mkdir -p "$work/parent"$'\n'"name"
run_sapi restore "$backup" --files $'parent\nname/../dir/line\t'
check "a newline cannot hide parent traversal in a selection" test "$rc" -ne 0

# Force replacement/rollback failures after the original has been set aside.
# The shim never affects archives or setup; it targets only restore renames.
cat >"$tmp/shim/mv" <<'SHIM'
#!/usr/bin/env bash
src="${@: -2:1}"
case "$src" in
    */.sapi-restore.*/item)
        case "${FAULT_MODE:-}" in
            signal) kill -TERM "$PPID" ;;
            collision) printf 'concurrent\n' >"${@: -1}" ;;
            signal-commit) "$REAL_MV" "$@" || exit $?; kill -TERM "$PPID"; exit 0 ;;
        esac
        exit 1 ;;
    */.sapi-restore.*/old)
        [[ "${FAULT_MODE:-}" == rollback ]] && exit 1 ;;
esac
exec "$REAL_MV" "$@"
SHIM
chmod +x "$tmp/shim/mv"
export REAL_MV="$real_mv"
new_workspace rollback
printf 'backup\n' >"$work/file"; snapshot
printf 'original\n' >"$work/file"
PATH="$tmp/shim:$PATH" run_sapi restore "$backup" --files file
check "replacement failure returns nonzero" test "$rc" -ne 0
check "replacement failure rolls the original back" test "$(<"$work/file")" = original
FAULT_MODE=rollback PATH="$tmp/shim:$PATH" run_sapi restore "$backup" --files file
saved="$(find "$work" -path '*/.sapi-restore.*/old' -type f -print)"
check "failed rollback retains the saved original" test -n "$saved"
check "saved original is intact" grep -qx original "$saved"
check "error identifies the recovery path" grep -Fq "original preserved at $saved" "$tmp/err"
if [[ -n "$saved" ]]; then "$real_mv" "$saved" "$work/file"; fi
printf 'original\n' >"$work/file"
FAULT_MODE=signal PATH="$tmp/shim:$PATH" run_sapi restore "$backup" --files file
check "signal during replacement returns 143" test "$rc" -eq 143
check "signal during replacement restores the original" test "$(<"$work/file")" = original
FAULT_MODE=collision PATH="$tmp/shim:$PATH" run_sapi restore "$backup" --files file
saved="$(find "$work" -path '*/.sapi-restore.*/old' -type f -print)"
check "rollback does not overwrite a reappeared destination" grep -qx concurrent "$work/file"
check "a destination collision preserves the saved original" test -n "$saved"
if [[ -n "$saved" ]]; then "$real_mv" "$saved" "$work/file"; fi
FAULT_MODE=signal-commit PATH="$tmp/shim:$PATH" run_sapi restore "$backup" --files file
saved="$(find "$work" -path '*/.sapi-restore.*/old' -type f -print)"
check "signal immediately after rename returns 143" test "$rc" -eq 143
check "signal after rename leaves the replacement intact" grep -qx backup "$work/file"
check "an uncertain commit retains the saved original" test -n "$saved"
if [[ -n "$saved" ]]; then "$real_mv" "$saved" "$tmp/uncertain-original"; fi
rm "$work/file"; ln -s missing-target "$work/file"
FAULT_MODE=rollback PATH="$tmp/shim:$PATH" run_sapi restore "$backup" --files file
saved="$(find "$work" -path '*/.sapi-restore.*/old' -type l -print)"
check "failed rollback also retains a dangling original symlink" test -n "$saved"
check "retained symlink target is intact" saved_link_target_is missing-target
rm "$tmp/shim/mv"

# Pause the lock creator after mkdir but before PID publication. A second
# writer must refuse, never remove the first process's incomplete lock.
cat >"$tmp/shim/mkdir" <<'SHIM'
#!/usr/bin/env bash
"$REAL_MKDIR" "$@" || exit $?
if [[ "${PAUSE_LOCK:-0}" == 1 && "${*: -1}" == */.backup.lock ]]; then
    : >"$LOCK_ENTERED"
    for ((i=0; i<200; i++)); do
        [[ -e "$LOCK_RELEASE" ]] && exit 0
        sleep 0.05
    done
    exit 1
fi
SHIM
chmod +x "$tmp/shim/mkdir"
export REAL_MKDIR="$real_mkdir" LOCK_ENTERED="$tmp/lock-entered" LOCK_RELEASE="$tmp/lock-release"
new_workspace locking
printf 'content\n' >"$work/file"; snapshot
root="${backup%/*}"
(cd "$work" && PAUSE_LOCK=1 PATH="$tmp/shim:$PATH" exec "$S" backup) >"$tmp/writer.out" 2>"$tmp/writer.err" &
writer=$!
wait_for "$LOCK_ENTERED"
run_sapi backup
check "unpublished lock refuses a concurrent writer" test "$rc" -ne 0
check "unpublished lock is not removed" test -d "$root/.backup.lock"
: >"$LOCK_RELEASE"
rc=0; wait "$writer" || rc=$?; writer=""
check "the lock creator can finish after contention" test "$rc" -eq 0
check "completed writer releases its lock" test ! -e "$root/.backup.lock"
rm "$tmp/shim/mkdir"

# Keep live/invalid locks, but recover a dead owner without losing backups.
mkdir -p "$root/.backup.lock"
printf '%s\n' "$$" >"$root/.backup.lock/pid"
run_sapi backup
check "live lock owner is not displaced" test "$rc" -ne 0
check "live lock PID is unchanged" test "$(<"$root/.backup.lock/pid")" = "$$"
printf 'invalid\n' >"$root/.backup.lock/pid"
run_sapi backup
check "malformed lock fails closed" test "$rc" -ne 0
check "malformed lock is retained for inspection" grep -qx invalid "$root/.backup.lock/pid"
mkdir -p "$root/.backup.lock"
printf '99999999\n' >"$root/.backup.lock/pid"
mkdir "$root/.backup.reap"
run_sapi backup
check "an existing recovery guard refuses another reaper" test "$rc" -ne 0
check "another reaper's guard is not removed" test -d "$root/.backup.reap"
check "a guarded stale lock is not removed" grep -qx 99999999 "$root/.backup.lock/pid"
rmdir "$root/.backup.reap"
run_sapi backup
check "dead lock owner is recovered" test "$rc" -eq 0
check "recovered lock is released" test ! -e "$root/.backup.lock"

# A delayed stale-owner observer must recheck, not remove a new owner's lock.
cat >"$tmp/shim/cat" <<'SHIM'
#!/usr/bin/env bash
if [[ "${*: -1}" == */.backup.lock/pid && ! -e "$LOCK_ENTERED" ]]; then
    value="$("$REAL_CAT" "$@")" || exit $?
    : >"$LOCK_ENTERED"
    for ((i=0; i<200; i++)); do
        if [[ -e "$LOCK_RELEASE" ]]; then printf '%s\n' "$value"; exit 0; fi
        sleep 0.05
    done
    exit 1
fi
exec "$REAL_CAT" "$@"
SHIM
chmod +x "$tmp/shim/cat"
export REAL_CAT="$real_cat"
rm "$LOCK_ENTERED" "$LOCK_RELEASE"
mkdir "$root/.backup.lock"; printf '99999999\n' >"$root/.backup.lock/pid"
(cd "$work" && PATH="$tmp/shim:$PATH" exec "$S" backup) >"$tmp/writer.out" 2>"$tmp/writer.err" &
writer=$!
wait_for "$LOCK_ENTERED"
run_sapi backup
check "a second reaper can recover the genuinely dead owner" test "$rc" -eq 0
mkdir "$root/.backup.lock"; printf '%s\n' "$$" >"$root/.backup.lock/pid"
: >"$LOCK_RELEASE"
rc=0; wait "$writer" || rc=$?; writer=""
check "a delayed reaper refuses changed ownership" test "$rc" -ne 0
check "a delayed reaper preserves the new live owner" grep -qx "$$" "$root/.backup.lock/pid"
rm -rf "$root/.backup.lock"; rm "$tmp/shim/cat"
check "stale recovery releases its own guard" test ! -e "$root/.backup.reap"

printf '\n%d recovery checks passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
