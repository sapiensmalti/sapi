#!/usr/bin/env bash
# Lint and unit checks. No Docker required.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }

echo "syntax"
check "sapi parses"        bash -n sapi
check "install.sh parses"  bash -n install.sh
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck sapi"       shellcheck -S warning sapi
    check "shellcheck install.sh" shellcheck -S warning install.sh
    check "shellcheck tests"      shellcheck -S warning test/*.sh
else
    echo "  skip shellcheck (not installed)"
fi

echo "cli"
check "version"            ./sapi version
check "--version"          ./sapi --version
check "help"               ./sapi help
check "rejects two args"   bash -c '! ./sapi a b'
check "rejects bad option" bash -c '! ./sapi --nope'

echo "dockerfile"
df="$(./sapi dockerfile)"
check "starts with syntax directive" grep -q '^# syntax=docker/dockerfile:1' <<<"$df"
check "has FROM"                     grep -q '^FROM node:' <<<"$df"
check "has entrypoint heredoc"       grep -q "^COPY <<'ENTRYPOINT_EOF' /usr/local/bin/sapi-entrypoint" <<<"$df"
check "heredoc is closed"            grep -q '^ENTRYPOINT_EOF$' <<<"$df"
check "ENTRYPOINT set"               grep -q '^ENTRYPOINT \["/usr/local/bin/sapi-entrypoint"\]' <<<"$df"
entry="$(sed -n "/^COPY <<'ENTRYPOINT_EOF'/,/^ENTRYPOINT_EOF$/p" <<<"$df" | sed '1d;$d')"
check "entrypoint parses"            bash -n <(printf '%s\n' "$entry")

echo "installer"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
check "installs from a local URL" env SAPI_URL="file://$PWD/sapi" SAPI_INSTALL_DIR="$tmp/bin" bash install.sh
check "installed file is executable" test -x "$tmp/bin/sapi"
check "installed file is identical"  cmp sapi "$tmp/bin/sapi"
echo garbage >"$tmp/bad"
check "rejects a non-sapi download"  bash -c "! SAPI_URL=file://$tmp/bad SAPI_INSTALL_DIR=$tmp/bin2 bash install.sh"
check "no stray files"               test ! -e "$tmp/bin2"

echo "hygiene"
check "LICENSE present"              test -f LICENSE
check "README present"               test -f README.md

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
