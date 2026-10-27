#!/usr/bin/env bash
# Image-selection and failure-path tests. Fake Docker only; no registry/network.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
S="$PWD/sapi"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" SAPI_CONFIG_FILE="$tmp/config" TMPDIR="$tmp/build-tmp"
export SAPI_UID=0 SAPI_GID=0
unset SAPI_BUILD SAPI_REBUILD SAPI_IMAGE SAPI_PI_VERSION SAPI_AUTO_UPDATE SAPI_PACKAGES SAPI_DOCKERFILE_EXTRA SAPI_NETWORK SAPI_ENV SAPI_DOCKER_ARGS
mkdir -p "$HOME" "$TMPDIR" "$tmp/bin" "$tmp/work"
base="$(awk -F '"' '/^readonly AGENT_IMAGE=/ {print $2}' "$S")"
# During test-first bootstrap no published pin exists yet. This reference is
# only a fixture, never a product pin or a network request.
base="${base:-ghcr.io/sapiensmalti/sapi-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000}"
pi_version="$(awk -F '"' '/^readonly AGENT_PI_VERSION=/ {print $2}' "$S")"
source_recipe="$(SAPI_BUILD=1 "$S" dockerfile)"
checksum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
definition="$(printf '%s\n%s\n' "$pi_version" "$source_recipe" | checksum | awk '{print $1}')"
export TEST_BASE="$base" TEST_PI="$pi_version" TEST_DEFINITION="$definition"
export CALLS="$tmp/calls" BASE_STATE="$tmp/base-state"
cat >"$tmp/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$1" in
    info) exit 0 ;;
    buildx) exit "${BUILDX_FAIL:-0}" ;;
    image)
        if [[ "${*: -1}" == "$TEST_BASE" ]]; then
            [[ -e "$BASE_STATE" || "${BASE_PRESENT:-1}" == 1 ]] || exit 1
        else
            [[ "${OTHER_PRESENT:-0}" == 1 ]] || exit 1
        fi
        case "$*" in
            *agent-definition*) [[ "${BAD_METADATA:-}" == definition ]] && echo wrong || echo "$TEST_DEFINITION" ;;
            *pi-version*) [[ "${BAD_METADATA:-}" == pi ]] && echo wrong || echo "$TEST_PI" ;;
            *Config.User*) [[ "${BAD_METADATA:-}" == user ]] && echo 1234:1234 || echo 0:0 ;;
            *--format*) echo image-id ;;
        esac
        exit 0 ;;
    pull) [[ "${PULL_FAIL:-0}" == 1 ]] && exit 1; : >"$BASE_STATE"; echo 'registry progress'; exit 0 ;;
    build) cat >"$CALLS.recipe"; echo 'build progress'; exit "${BUILD_FAIL:-0}" ;;
    volume) echo volume; exit 0 ;;
    run) printf '%s\n' "$@" >"$CALLS.args"; echo answer; exit 0 ;;
    rm|stop) exit 0 ;;
    *) exit 1 ;;
esac
SHIM
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
pass=0; fail=0
check() {
    local message="$1"; shift
    if "$@"; then pass=$((pass+1)); printf '  ok   %s\n' "$message"
    else fail=$((fail+1)); printf '  FAIL %s\n' "$message" >&2; fi
}
call() {
    : >"$CALLS"; rm -f "$BASE_STATE" "$CALLS.recipe" "$CALLS.args"; rc=0
    (cd "$tmp/work" && "$S" "$@") >"$tmp/out" 2>"$tmp/err" || rc=$?
}
no_build() { ! grep -q '^build ' "$CALLS"; }
no_pull() { ! grep -q '^pull ' "$CALLS"; }
starts_with_base() { grep -qFx "FROM $base" "$CALLS.recipe"; }
no_resources() { ! grep -qE '^(run |volume )' "$CALLS"; }
call build
check 'cached default image is accepted' test "$rc" -eq 0
check 'cached default never builds locally' no_build
check 'cached default does not contact registry' no_pull
check 'cached default validates its build definition' grep -q agent-definition "$CALLS"
BUILDX_FAIL=1 call build
check 'default published image does not require Buildx' test "$rc" -eq 0
BASE_PRESENT=0 call build
check 'cold default pull succeeds' test "$rc" -eq 0
check 'cold default pulls the exact digest' grep -Fxq "pull --quiet $base" "$CALLS"
check 'cold default does not run npm/apt build' no_build
BASE_PRESENT=0 PULL_FAIL=1 call build
check 'registry failure is reported' test "$rc" -eq 1
check 'registry failure never silently builds from mutable inputs' no_build
check 'registry failure suggests an explicit source build' grep -q SAPI_BUILD "$tmp/err"
for field in definition pi user; do
    BAD_METADATA="$field" call build
    check "bad $field metadata is refused" test "$rc" -eq 1
    check "bad $field metadata cannot trigger a source fallback" no_build
    BAD_METADATA="$field" call run test
    check "bad $field metadata aborts agent launch" test "$rc" -eq 1
    check "bad $field metadata cannot create credentials/session volumes" no_resources
done
SAPI_BUILD=1 BUILDX_FAIL=1 call build
check 'source build without Buildx is refused' test "$rc" -eq 1
check 'missing Buildx has an actionable diagnostic' grep -q docker-buildx-plugin "$tmp/err"
check 'missing Buildx does not start a build' no_build
SAPI_BUILD=1 call build
check 'explicit source build succeeds' test "$rc" -eq 0
check 'explicit source build uses Node recipe' grep -q '^FROM node:' "$CALLS.recipe"
check 'explicit source build never pulls published base' no_pull
check 'source build receives requested pi version' grep -Fq -- "--build-arg PI_VERSION=$pi_version" "$CALLS"
SAPI_PI_VERSION=latest call build
check 'explicit latest pi uses source build' grep -q '^FROM node:' "$CALLS.recipe"
check 'explicit latest is passed as build argument' grep -Fq -- '--build-arg PI_VERSION=latest' "$CALLS"
SAPI_REBUILD=1 call build
check 'forced rebuild uses full source recipe' grep -q '^FROM node:' "$CALLS.recipe"
check 'forced rebuild bypasses cache and refreshes source inputs' grep -q -- '--no-cache --pull' "$CALLS"
SAPI_PACKAGES='make file' call build
check 'package customization succeeds' test "$rc" -eq 0
check 'packages extend the pinned base, not a fresh npm install' starts_with_base
check 'package layer contains requested tools' grep -q 'apt-get install.*make file' "$CALLS.recipe"
printf 'USER 1234:1234\nRUN echo fragment\n' >"$tmp/fragment"
SAPI_DOCKERFILE_EXTRA="$tmp/fragment" call build
check 'fragment extends the pinned base' starts_with_base
check 'fragment is retained' grep -q '^RUN echo fragment$' "$CALLS.recipe"
check 'fragment cannot change final root identity' test "$(tail -n1 "$CALLS.recipe")" = 'USER 0:0'
SAPI_PACKAGES=file OTHER_PRESENT=1 BASE_PRESENT=0 call build
check 'cached customized image is reusable' test "$rc" -eq 0
check 'cached customization does not require base download' no_pull
check 'cached customization does not rebuild' no_build
SAPI_IMAGE=chosen-image OTHER_PRESENT=1 BASE_PRESENT=0 call build
check 'explicit cached image remains usable' test "$rc" -eq 0
check 'explicit cached image does not need canonical base metadata' no_pull
SAPI_IMAGE=local-build-name call build
check 'missing explicit output tag builds a thin default layer' starts_with_base
check 'explicit output tag is honored' grep -q -- '--tag local-build-name' "$CALLS"
SAPI_BUILD=1 SAPI_IMAGE=local-build-name call build
check 'explicit source build with output tag remains supported' grep -q '^FROM node:' "$CALLS.recipe"
SAPI_BUILD=1 BUILD_FAIL=7 call build
check 'failed source build propagates failure' test "$rc" -ne 0
check 'failed build removes its private context' test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
SAPI_BUILD=bad call build
check 'invalid build-mode override is refused' test "$rc" -eq 1
check 'invalid build-mode fails before Docker actions' test ! -s "$CALLS"
call run test
check 'default headless agent can start from cached image' test "$rc" -eq 0
check 'automatic pi update stays enabled by default (policy B)' grep -qx SAPI_AUTO_UPDATE=1 "$CALLS.args"
check 'root identity is unchanged' grep -qx 0:0 "$CALLS.args"
BASE_PRESENT=0 call run test
check 'pull progress never contaminates the final-message stdout' test "$(<"$tmp/out")" = answer
SAPI_BUILD=1 call run test
check 'build progress never contaminates the final-message stdout' test "$(<"$tmp/out")" = answer
printf '\n%d distribution checks passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
