#!/usr/bin/env bash
# Runs on Linux (GNU coreutils); this is what CI executes. shellcheck optional.
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

echo "config"
REAL_HOME="$HOME"; export HOME; HOME="$(mktemp -d)"; proj="$HOME/proj"; mkdir -p "$proj/sub"; echo a >"$proj/a.txt"; echo b >"$proj/sub/b.txt"; ln -s a.txt "$proj/link"; chmod 600 "$proj/a.txt"
S="$PWD/sapi"
check "defaults: safer off"           bash -c "cd $proj && $S config show | grep -q 'safer *false *(default)'"
check "config set safer"              bash -c "cd $proj && $S config set safer yes && grep -qx 'safer = true' \$($S config path)"
check "config file is 0600"           bash -c "[[ \$(stat -c %a $HOME/.config/sapi/config) == 600 ]]"
check "config set replaces in place"  bash -c "cd $proj && $S config set safer no && [[ \$(grep -c safer \$($S config path)) == 1 ]] && $S config set safer true"
check "config wins over default"      bash -c "cd $proj && $S config show | grep -q 'safer *true *(config)'"
check "env wins over config"          bash -c "cd $proj && SAPI_SAFER=0 $S config show | grep -q 'safer *false *(environment)'"
check "flag wins over env"            bash -c "cd $proj && SAPI_SAFER=0 $S --safer config show | grep -q 'safer *true *(flag)'"
check "last flag wins"                bash -c "cd $proj && $S --safer --no-safer config show | grep -q 'safer *false *(flag)'"
check "rejects bad bool"              bash -c "! $S config set safer maybe"
check "rejects relative backup_dir"   bash -c "! $S config set backup_dir rel/path"
check "rejects unknown key"           bash -c "! $S config set bogus 1"
check "unknown key in file refuses"   bash -c "echo 'typo = 1' >> $HOME/.config/sapi/config && ! $S config show; sed -i.bak '/typo/d' $HOME/.config/sapi/config"
check "never sources the file"        bash -c "echo 'safer = \$(touch $HOME/pwned)' >> $HOME/.config/sapi/config; ! $S config show; [[ ! -e $HOME/pwned ]]; sed -i.bak '/pwned/d' $HOME/.config/sapi/config"

echo "backup"
b="$(cd "$proj" && "$S" backup 2>/dev/null)" && ok "creates a backup" || bad "creates a backup"
check "archive, checksum and manifest exist" test -f "$b" -a -f "$b.sha256" -a -f "$b.manifest"
check "files are 0600 in a 0700 dir"  bash -c "[[ \$(stat -c %a '$b') == 600 && \$(stat -c %a '$(dirname "$b")') == 700 ]]"
check "checksum verifies"             bash -c "cd '$(dirname "$b")' && sha256sum -c --quiet '$(basename "$b").sha256'"
check "manifest records the source"   grep -qx "source = $proj" "$b.manifest"
check "archive is complete"           bash -c "tar -tzf '$b' | grep -qx proj/sub/b.txt && tar -tzf '$b' | grep -qx proj/link"
d="$(cd "$proj" && "$S" restore "$b" 2>/dev/null)" && ok "restores into a new directory" || bad "restore"
check "restore is byte-identical"     diff -r "$proj" "$d"
check "restore keeps modes and links" bash -c "[[ \$(stat -c %a '$d/a.txt') == 600 && -L '$d/link' ]]"
check "restore never overwrites"      bash -c "cd $proj && ! $S restore '$b' $proj"
check "restore refuses a corrupt archive" bash -c "cp '$b' $HOME/c.tar.gz; cp '$b.sha256' $HOME/c.tar.gz.sha256; printf x >> $HOME/c.tar.gz; ! $S restore $HOME/c.tar.gz $HOME/out"
check "refuses backup dir inside workspace, creates nothing" bash -c "cd $proj && ! SAPI_BACKUP_DIR=$proj/.bk $S backup && [[ ! -e $proj/.bk ]]"
check "refuses symlinked dir inside workspace" bash -c "ln -s $proj $HOME/plink && cd $proj && ! SAPI_BACKUP_DIR=$HOME/plink/.bk $S backup && [[ ! -e $proj/.bk ]]"
check "refuses to back up /"         bash -c "cd / && ! $S backup"
shim="$(mktemp -d)"
printf '#!/bin/sh\ncase "$1" in -czf) echo boom >&2; exit 2;; esac\nexec /bin/tar "$@"\n' >"$shim/tar"; chmod +x "$shim/tar"
n_before="$(cd "$proj" && "$S" backups | wc -l)"
check "fatal tar aborts, leaves no archive or partial" bash -c "cd $proj && ! PATH=$shim:\$PATH $S backup && [[ \$($S backups | wc -l) == $n_before ]] && [[ -z \$(find $HOME/.local/share/sapi -name '*.partial') ]]"
printf '#!/bin/sh\ncase "$1" in -czf) /bin/tar "$@"; exit 1;; esac\nexec /bin/tar "$@"\n' >"$shim/tar"
check "tar exit 1 keeps the archive and records it" bash -c "cd $proj && b2=\$(PATH=$shim:\$PATH $S backup 2>/dev/null) && grep -qx 'tar_exit = 1' \$b2.manifest"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "x 1 1 1 1 /"\n' >"$shim/df"; chmod +x "$shim/df"
check "insufficient space aborts"    bash -c "cd $proj && ! PATH=$shim:\$PATH $S backup"
check "prunes to backup_keep"        bash -c "cd $proj && for i in 1 2 3 4; do sleep 1; SAPI_BACKUP_KEEP=2 $S backup >/dev/null 2>&1; done; [[ \$($S backups | wc -l) == 2 ]] && [[ \$(ls '$(dirname "$b")' | wc -l) == 6 ]]"
check "backup_keep=0 keeps all"      bash -c "cd $proj && SAPI_BACKUP_KEEP=0 $S backup >/dev/null 2>&1 && [[ \$($S backups | wc -l) == 3 ]]"
rm -rf "$HOME" "$shim"; HOME="$REAL_HOME"

echo "hygiene"
check "LICENSE present"              test -f LICENSE
check "README present"               test -f README.md

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
