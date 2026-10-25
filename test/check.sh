#!/usr/bin/env bash
# Portable Linux/macOS lint and unit checks. No Docker required.
# The linter is optional locally and mandatory in CI.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }
stat_mode() { if stat -c %a / >/dev/null 2>&1; then stat -c %a -- "$1"; else stat -f %Lp "$1"; fi; }
checksum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
SCRIPT_KIND=bsd
if script -qec true /dev/null >/dev/null 2>&1; then SCRIPT_KIND=gnu; fi
run_tty() {
    if [[ "$SCRIPT_KIND" == gnu ]]; then
        local cmd
        printf -v cmd '%q ' "$@"
        script -qec "$cmd" /dev/null
    else
        script -q /dev/null "$@"
    fi
}

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
check "bad upgrade keeps the working installation" bash -c "echo garbage >$tmp/bad; ! SAPI_URL=file://$tmp/bad SAPI_INSTALL_DIR=$tmp/bin bash install.sh >/dev/null 2>&1 && cmp sapi $tmp/bin/sapi && [[ -z \$(find $tmp/bin -name '.sapi.new.*') ]]"
mkdir "$tmp/linkbin"; echo original >"$tmp/target"; ln -s "$tmp/target" "$tmp/linkbin/sapi"
check "install replaces, never follows, a destination symlink" bash -c "SAPI_URL=file://$PWD/sapi SAPI_INSTALL_DIR=$tmp/linkbin bash install.sh >/dev/null 2>&1 && [[ ! -L $tmp/linkbin/sapi && \$(cat $tmp/target) == original ]]"
echo garbage >"$tmp/bad"
check "rejects a non-sapi download"  bash -c "! SAPI_URL=file://$tmp/bad SAPI_INSTALL_DIR=$tmp/bin2 bash install.sh"
check "no stray files"               test ! -e "$tmp/bin2"
mkdir "$tmp/up" "$tmp/ushim"; cp sapi "$tmp/up/sapi"
cat >"$tmp/ushim/curl" <<'US'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UPGRADE_CALLS"
cat <<'INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "${SAPI_REF:-}" >"$SAPI_INSTALL_DIR/ref"
INSTALLER
US
chmod +x "$tmp/ushim/curl"
check "default upgrade follows the current installer, not its own old tag" bash -c "UPGRADE_CALLS=$tmp/ushim/calls PATH=$tmp/ushim:\$PATH $tmp/up/sapi upgrade >/dev/null 2>&1 && grep -q '/main/install.sh' $tmp/ushim/calls && [[ -z \$(cat $tmp/up/ref) ]]"
check "explicit SAPI_REF controls both upgrade downloads" bash -c ": >$tmp/ushim/calls; UPGRADE_CALLS=$tmp/ushim/calls PATH=$tmp/ushim:\$PATH SAPI_REF=v1.2.3 $tmp/up/sapi upgrade >/dev/null 2>&1 && grep -q '/v1.2.3/install.sh' $tmp/ushim/calls && [[ \$(cat $tmp/up/ref) == v1.2.3 ]]"

echo "config"
REAL_HOME="$HOME"; export HOME; HOME="$(mktemp -d)"; export SAPI_CONFIG_FILE="$HOME/.config/sapi/config"; proj="$HOME/proj"; mkdir -p "$proj/sub"; echo a >"$proj/a.txt"; echo b >"$proj/sub/b.txt"; ln -s a.txt "$proj/link"; chmod 600 "$proj/a.txt"
S="$PWD/sapi"
check "defaults: safer off"           bash -c "cd $proj && $S config show | grep -q 'safer *false *(default)'"
check "config set safer"              bash -c "cd $proj && $S config set safer yes && grep -qx 'safer = true' \$($S config path)"
check "config file is 0600"           bash -c "[[ \$(if stat -c %a / >/dev/null 2>&1; then stat -c %a $HOME/.config/sapi/config; else stat -f %Lp $HOME/.config/sapi/config; fi) == 600 ]]"
check "config set replaces in place"  bash -c "cd $proj && $S config set safer no && [[ \$(grep -c safer \$($S config path)) == 1 ]] && $S config set safer true"
check "config wins over default"      bash -c "cd $proj && $S config show | grep -q 'safer *true *(config)'"
check "env wins over config"          bash -c "cd $proj && SAPI_SAFER=0 $S config show | grep -q 'safer *false *(environment)'"
check "set-but-empty env clears a configured list" bash -c "cd $proj && $S config set packages 'make jq' >/dev/null && SAPI_PACKAGES= $S config show | grep -q '^packages  *(environment)$' && $S config set packages '' >/dev/null"
check "allow wildcards are not host-glob expanded" bash -c "cd $proj && touch a.github.com z.github.com && SAPI_ALLOW='*.github.com' $S config show | grep -q '^allow        \\*.github.com  (environment)$'"
check "paths containing # round-trip through config" bash -c "cd $proj && $S config set backup_dir '/tmp/a#b' >/dev/null && $S config show | grep -q '^backup_dir   /tmp/a#b  (config)$' && $S config set backup_dir '$HOME/.local/share/sapi/backups' >/dev/null"
check "unexpected command arguments are rejected" bash -c "! $S backup extra && ! $S ls extra && ! $S version extra && ! $S config keys extra"
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
check "files are 0600 in a 0700 dir"  bash -c "[[ \$(if stat -c %a / >/dev/null 2>&1; then stat -c %a '$b'; else stat -f %Lp '$b'; fi) == 600 && \$(if stat -c %a / >/dev/null 2>&1; then stat -c %a '$(dirname "$b")'; else stat -f %Lp '$(dirname "$b")'; fi) == 700 ]]"
b_sha="$(checksum <"$b")"; check "checksum verifies" test "$b_sha" = "$(awk '{print $1}' "$b.sha256")"
check "manifest records the source"   grep -qx "source = $proj" "$b.manifest"
check "archive is complete"           bash -c "tar -tzf '$b' | grep -qx proj/sub/b.txt && tar -tzf '$b' | grep -qx proj/link"
d="$(cd "$proj" && "$S" restore "$b" 2>/dev/null)" && ok "restores into a new directory" || bad "restore"
check "restore is byte-identical"     diff -r "$proj" "$d"
check "restore keeps modes and links" bash -c "[[ \$(if stat -c %a / >/dev/null 2>&1; then stat -c %a '$d/a.txt'; else stat -f %Lp '$d/a.txt'; fi) == 600 && -L '$d/link' ]]"
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
backup_root="$(dirname "$b")"
check "a live backup lock refuses a concurrent writer" bash -c "mkdir $backup_root/.backup.lock; echo \$\$ >$backup_root/.backup.lock/pid; cd $proj && ! $S backup >/dev/null 2>&1; rc=\$?; rmdir_lock=\$(cat $backup_root/.backup.lock/pid); rm -rf $backup_root/.backup.lock; [[ \$rc == 0 && \$rmdir_lock == \$\$ ]]"
check "a stale backup lock is recovered" bash -c "mkdir $backup_root/.backup.lock; echo 99999999 >$backup_root/.backup.lock/pid; cd $proj && $S backup >/dev/null 2>&1 && [[ ! -e $backup_root/.backup.lock ]]"
check "orphan metadata is cleaned without deleting valid backups" bash -c "echo orphan >$backup_root/20000101T000000Z.tar.gz.manifest; cd $proj && SAPI_BACKUP_KEEP=0 $S backup >/dev/null 2>&1 && [[ ! -e $backup_root/20000101T000000Z.tar.gz.manifest && \$($S backups | wc -l) -gt 0 ]]"
printf '#!/bin/sh\necho unreadable >&2\nexit 1\n' >"$shim/du"; chmod +x "$shim/du"
check "du failure aborts instead of silently skipping the space check" bash -c "cd $proj && ! PATH=$shim:\$PATH $S backup >/dev/null 2>&1"
rm -f "$shim/du"
check "an existing backup root is made private" bash -c "chmod 0777 $backup_root; cd $proj && $S backup >/dev/null 2>&1 && [[ \$(if stat -c %a / >/dev/null 2>&1; then stat -c %a $backup_root; else stat -f %Lp $backup_root; fi) == 700 ]]"

echo "toolchain"
check "packages normalised"            bash -c "cd $proj && $S config set packages 'golang, make  jq' && grep -qx 'packages = golang make jq' \$($S config path)"
check "packages rejects shell metacharacters" bash -c "! $S config set packages 'x; rm -rf /' && ! $S config set packages '\$(id)' && ! $S config set packages 'a b/c'"
check "packages appear in the effective Dockerfile" bash -c "cd $proj && $S dockerfile | grep -q 'apt-get install -y --no-install-recommends golang make jq'"
df_hash="$(cd "$proj" && "$S" dockerfile | checksum)"; df_hash_make="$(cd "$proj" && env SAPI_PACKAGES=make "$S" dockerfile | checksum)"
check "packages change the image digest input" test "$df_hash" != "$df_hash_make"
check "Dockerfile.extra is appended when present" bash -c "printf 'RUN echo extra\\n' > $HOME/.config/sapi/Dockerfile.extra && cd $proj && $S dockerfile | grep -q '^RUN echo extra'"
check "embedded Dockerfile comes first, unchanged" bash -c "cd $proj && $S dockerfile | grep -n '^ENTRYPOINT' | cut -d: -f1 | xargs -I{} test {} -lt \$($S dockerfile | grep -n 'RUN echo extra' | cut -d: -f1)"
check "project-level Dockerfile.extra is ignored" bash -c "printf 'RUN evil\\n' > $proj/Dockerfile.extra && cd $proj && ! $S dockerfile | grep -q evil; rm -f $proj/Dockerfile.extra"
check "dockerfile_extra path is configurable" bash -c "printf 'RUN elsewhere\\n' > $HOME/other.df && cd $proj && SAPI_DOCKERFILE_EXTRA=$HOME/other.df $S dockerfile | grep -q elsewhere"
"$S" config set packages "" >/dev/null 2>&1 || sed -i.bak '/^packages/d' "$($S config path)"; rm -f "$HOME/.config/sapi/Dockerfile.extra"

echo "network (settings + launcher ordering via shim)"
check "network defaults to full"             bash -c "cd $proj && $S config show | grep -q 'network *full *(default)'"
check "allow defaults to @providers"         bash -c "cd $proj && $S config show | grep -q 'allow *@providers *(default)'"
check "network rejects other values"         bash -c "! $S config set network sometimes"
check "allow accepts presets, hosts, wildcards, ports" bash -c "cd $proj && $S config set allow '@github, *.example.org api.example.com:443' >/dev/null"
check "allow rejects ports the firewall cannot redirect and invalid DNS labels" bash -c "! $S config set allow example.com:8443 && ! $S config set allow example.com:65536 && ! $S config set allow -bad.example && ! $S config set allow bad-.example"
check "allow rejects unknown preset"         bash -c "! $S config set allow @nope"
check "allow rejects metacharacters"         bash -c "! $S config set allow 'a;b' && ! $S config set allow '*.' && ! $S config set allow 'a..b' && ! $S config set allow '\$(id).com'"
nshim="$(mktemp -d)"
cat >"$nshim/docker" <<NS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $nshim/calls
case "\$1" in
  info|image|exec|stop) exit 0 ;;
  volume) echo v ;;
  container) case "\$2" in inspect) [[ "\$*" == *".State.Running"* ]] && echo true || exit 1 ;; *) exit 0 ;; esac ;;
  run) [[ "\$*" == *--detach* ]] && { echo id; exit 0; }; echo "Answer"; exit 0 ;;
  *) exit 0 ;;
esac
NS
chmod +x "$nshim/docker"
run_net() { : >"$nshim/calls"; (cd "$proj" && env "$@" PATH="$nshim:$PATH" "$S" run x >/dev/null 2>"$nshim/err"); }
run_net SAPI_NETWORK=allowlist SAPI_ALLOW="@providers @github"
check "sidecar starts before the agent, ready is probed between" bash -c "grep -nE '^(run --detach|exec .*test -f /run/egress/ready|run --rm)' $nshim/calls | cut -d: -f2 | cut -c1-12 | tr '\n' ' ' | grep -q '^run --detach exec .*run --rm'"
check "sidecar gets NET_ADMIN SETUID SETGID only, hardened" bash -c "l=\$(grep '^run --detach' $nshim/calls); [[ \$l == *'--cap-drop ALL'* && \$l == *'--cap-add NET_ADMIN'* && \$l == *'--security-opt no-new-privileges'* && \$l == *'--pids-limit'* ]] && ! [[ \$l == *'--privileged'* ]]"
check "presets are expanded for the sidecar"  bash -c "grep '^run --detach' $nshim/calls | grep -q 'EGRESS_ALLOW=api.anthropic.com .*github.com'"
check "agent shares the sidecar namespace, no hostname" bash -c "l=\$(grep '^run --rm' $nshim/calls); [[ \$l == *'--network container:'*'-egress'* ]] && ! [[ \$l == *'--hostname'* ]]"
check "agent never gets the docker socket or NET_ADMIN" bash -c "! grep '^run --rm' $nshim/calls | grep -qE 'docker.sock|NET_ADMIN'"
check "sidecar is removed after the run"      bash -c "tail -n1 $nshim/calls | grep -q '^rm --force .*-egress'"
: >"$nshim/calls"
check "agent uid cannot inherit the proxy firewall exemption" bash -c "cd $proj && ! SAPI_UID=65532 SAPI_NETWORK=allowlist PATH=$nshim:\$PATH $S run x >/dev/null 2>&1"
check "uid collision fails before any sidecar starts" bash -c "! grep -q -- --detach $nshim/calls"
run_net SAPI_NETWORK=allowlist SAPI_ALLOW="@providers @github"
check "self-update skipped without @npm"      bash -c "grep '^run --rm' $nshim/calls | grep -q 'SAPI_AUTO_UPDATE=0' && grep -q 'skipping pi self-update' $nshim/err"
run_net SAPI_NETWORK=allowlist SAPI_ALLOW="@providers @npm"
check "self-update kept with @npm"            bash -c "grep '^run --rm' $nshim/calls | grep -q 'SAPI_AUTO_UPDATE=1'"
run_net SAPI_NETWORK=full
check "full mode: no sidecar, hostname set"   bash -c "! grep -q -- --detach $nshim/calls && grep '^run --rm' $nshim/calls | grep -q -- '--hostname sapi'"
check "egress image is pinned by digest"      bash -c "grep -q 'sapi-egress@sha256:[0-9a-f]\{64\}' $S && grep -q 'EGRESS_SOURCE_SHA256=\"[0-9a-f]\{64\}\"' $S"
rm -rf "$nshim"

echo "interactive resume (stateful docker shim)"
stshim="$(mktemp -d)"
cat >"$stshim/docker" <<ST
#!/usr/bin/env bash
printf '%s\n' "\$*" >>$stshim/calls
state=$stshim/state
case "\$1" in
  info) exit 0 ;;
  image) [[ "\$*" == *'.Id'* ]] && echo image-id; exit 0 ;;
  volume) echo volume; exit 0 ;;
  container)
    if [[ "\$2" == inspect ]]; then
      if [[ "\$3" == --format ]]; then
        fmt="\$4"
        case "\$fmt" in
          *State.Status*) echo exited; exit 0 ;;
          *.Image*) echo image-id; exit 0 ;;
          *Config.Labels*)
            key="\${fmt#*\"}"; key="\${key%%\"*}"; file="\$(printf '%s' "\$key" | tr . _)"
            [[ -f "\$state/\$file" ]] && cat "\$state/\$file"
            exit 0 ;;
        esac
      fi
      [[ -d "\$state" ]]; exit
    fi
    [[ "\$2" == rm ]] && rm -rf "\$state"
    exit 0 ;;
  create)
    rm -rf "\$state"; mkdir -p "\$state"; printf '%s\n' create >>$stshim/actions
    while [[ \$# -gt 0 ]]; do
      if [[ "\$1" == --label ]]; then
        shift; label="\$1"; key="\${label%%=*}"; value="\${label#*=}"; file="\$(printf '%s' "\$key" | tr . _)"
        printf '%s' "\$value" >"\$state/\$file"
      fi
      shift
    done
    echo id; exit 0 ;;
  start) printf '%s\n' attach >>$stshim/actions; exit 0 ;;
  *) exit 0 ;;
esac
ST
chmod +x "$stshim/docker"
start_run() { (cd "$proj" && run_tty env PATH="$stshim:$PATH" SAPI_AUTO_UPDATE=0 "$@" "$S" >/dev/null 2>&1); }
: >"$stshim/actions"
start_run
check "first interactive start creates a container" bash -c "[[ \$(grep -c '^create' $stshim/actions) == 1 ]]"
start_run
check "identical settings resume the stopped container" bash -c "[[ \$(grep -c '^create' $stshim/actions) == 1 && \$(grep -c '^attach' $stshim/actions) == 2 ]]"
start_run SAPI_CPUS=2
check "resource ceiling changes recreate instead of resuming stale limits" bash -c "[[ \$(grep -c '^create' $stshim/actions) == 2 ]]"
start_run SAPI_CONFIG_VOLUME=other-config
check "config volume changes recreate instead of keeping the old mount" bash -c "[[ \$(grep -c '^create' $stshim/actions) == 3 ]]"
start_run SAPI_ENV=TEST_TOKEN TEST_TOKEN=one
start_run SAPI_ENV=TEST_TOKEN TEST_TOKEN=one
check "passed environments always refresh so values cannot become stale" bash -c "[[ \$(grep -c '^create' $stshim/actions) == 5 ]]"
rm -rf "$stshim"

echo "shell (docker shim)"
sshim="$(mktemp -d)"
cat >"$sshim/docker" <<SS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $sshim/calls
case "\$1" in
  info|image) exit 0 ;;
  volume) [[ "\$2" == inspect && "\$*" == *runs-sessions* ]] && exit "\${RUNS_EXIST_RC:-1}"; echo v; exit 0 ;;
  container) if [[ "\$2" == ls ]]; then printf '%s' "\${RUNNING:-}"; exit 0; fi; [[ "\$*" == *sessions-volume* ]] && echo somevol; exit 0 ;;
  exec|run) exit 0 ;;
  *) exit 0 ;;
esac
SS
chmod +x "$sshim/docker"
shell_run() { : >"$sshim/calls"; (cd "$proj" && run_tty env "$@" PATH="$sshim:$PATH" "$S" shell ${SHELL_ARGS:-} >/dev/null 2>&1); true; }
shell_run
check "ephemeral shell when nothing runs"      bash -c "grep -q '^run ' $sshim/calls && ! grep -q '^exec ' $sshim/calls"
check "shell lands in /pi-sessions via the entrypoint (SAPI_CMD=bash)" bash -c "l=\$(grep '^run ' $sshim/calls); [[ \$l == *'SAPI_CMD=bash'* ]] && [[ \$(grep -o -- '--workdir [^ ]*' <<<\"\$l\" | tail -1) == '--workdir /pi-sessions' ]]"
check "ephemeral shell is hardened and removed"   bash -c "l=\$(grep '^run ' $sshim/calls); [[ \$l == *'--rm'* && \$l == *'--cap-drop ALL'* && \$l == *'no-new-privileges'* && \$l == *'SAPI_AUTO_UPDATE=0'* ]]"
check "ephemeral shell has no network by default" bash -c "grep '^run ' $sshim/calls | grep -q -- '--network none'"
check "no runs volume → not mounted"            bash -c "! grep '^run ' $sshim/calls | grep -q pi-sessions-runs"
SHELL_ARGS=--net shell_run RUNS_EXIST_RC=0
check "--net enables network"                   bash -c "! grep '^run ' $sshim/calls | grep -q -- '--network none'"
check "runs volume mounted when present"        bash -c "grep '^run ' $sshim/calls | grep -q 'target=/pi-sessions-runs'"
SHELL_ARGS="" shell_run RUNNING=sapi-proj-x
check "running agent → exec into it, in /pi-sessions, as the user" bash -c "l=\$(grep '^exec ' $sshim/calls); [[ \$l == *'--workdir /pi-sessions'* && \$l == *'--user '* && \$l == *' sapi-proj-x bash'* ]] && ! grep -q '^run ' $sshim/calls"
check "shell rejects unknown options"           bash -c "cd $proj && ! PATH=$sshim:\$PATH $S shell --bogus 2>/dev/null"
check "entrypoint honours SAPI_CMD and skips update for shells" bash -c "cd $proj && $S dockerfile | grep -q 'cmd=\"\${SAPI_CMD:-pi}\"' && $S dockerfile | grep -q '\[ \"\$cmd\" = \"pi\" \] && \[ \"\${SAPI_AUTO_UPDATE:-1}\" = \"1\" \]'"
rm -rf "$sshim"

echo "diff / selective restore"
rm -rf "$HOME/.local/share/sapi"; echo hello >"$proj/a.txt"; echo keep >"$proj/c.txt"; echo dots >"$proj/a..b"
echo one >"$proj/same-a"; cp "$proj/same-a" "$proj/same-b"; ln -sfn same-a "$proj/link"
(cd "$proj" && "$S" backup >/dev/null 2>&1)
check "no changes → exit 0"            bash -c "cd $proj && $S diff 2>/dev/null"
echo changed >"$proj/a.txt"; rm "$proj/c.txt"; echo new >"$proj/sub/n.txt"; mkdir -p "$proj/d"; echo x >"$proj/d/e.txt"
out="$(cd "$proj" && "$S" diff 2>/dev/null)" && bad "diff exits 1 when there are changes" || ok "diff exits 1 when there are changes"
check "diff marks M"                   grep -qx "M  a.txt" <<<"$out"
check "diff marks D"                   grep -qx "D  c.txt" <<<"$out"
check "diff marks A (nested)"          grep -qx "A  sub/n.txt" <<<"$out"
check "diff marks A (directory)"       grep -qx "A  d" <<<"$out"
check "diff --full shows hunks"        bash -c "cd $proj && $S diff --full 2>/dev/null | grep -q '^+changed'"
check "diff verifies the checksum"     bash -c "b=\$(ls $HOME/.local/share/sapi/backups/*/*.tar.gz); cp \$b \$b.corrupt; printf x >> \$b.corrupt; ! $S diff \$b.corrupt 2>/dev/null"
check "diff detects a same-content symlink retarget" bash -c "cd $proj && ln -sfn same-b link && out=\$($S diff 2>/dev/null); [[ \$? == 1 && \$out == *'M  link'* ]]"
check "diff detects a mode-only change" bash -c "cd $proj && chmod 600 same-a && out=\$($S diff 2>/dev/null); [[ \$? == 1 && \$out == *'M  same-a'* ]]"
check "diff handles dangling links without following them" bash -c "cd $proj && ln -s /not/here dangling && ln -s $HOME escape && echo private >$HOME/outside.txt && out=\$($S diff 2>/dev/null); [[ \$? == 1 && \$out == *'A  dangling'* && \$out == *'A  escape'* && \$out != *outside.txt* ]]"
check "restore --files puts back a deleted file" bash -c "cd $proj && $S restore latest --files c.txt >/dev/null && [[ \$(cat c.txt) == keep ]]"
check "restore --files reverts a modified file" bash -c "cd $proj && $S restore latest --files a.txt >/dev/null && [[ \$(cat a.txt) == hello ]]"
check "restore --files leaves other changes"    bash -c "cd $proj && [[ -f sub/n.txt && -f d/e.txt ]]"
check "restore --files refuses .. and absolute"  bash -c "cd $proj && ! $S restore latest --files ../x && ! $S restore latest --files /etc"
check "restore --files refuses unknown path"     bash -c "cd $proj && ! $S restore latest --files nope"
check "restore --files accepts .. inside a filename" bash -c "cd $proj && echo changed >a..b && $S restore latest --files a..b >/dev/null && [[ \$(cat a..b) == dots ]]"
check "restore --files refuses wildcards unless such a file exists" bash -c "cd $proj && ! $S restore latest --files '*' >/dev/null 2>&1"
check "directory restore replaces the selected tree exactly" bash -c "cd $proj && $S restore latest --files sub >/dev/null && [[ -f sub/b.txt && ! -e sub/n.txt && -f d/e.txt ]]"
check "restore refuses to traverse a destination symlink" bash -c "cd $proj && echo sentinel >$HOME/b.txt && rm -rf sub && ln -s $HOME sub && ! $S restore latest --files sub/b.txt >/dev/null 2>&1 && [[ \$(cat $HOME/b.txt) == sentinel ]]"
check "restoring a link replaces the link, not its target" bash -c "cd $proj && $S restore latest --files link >/dev/null && [[ \$(readlink link) == same-a ]]"
check "restore rejects an archive with multiple roots" bash -c "mkdir -p $HOME/tar/one $HOME/tar/two; echo x >$HOME/tar/one/x; echo y >$HOME/tar/two/y; tar -czf $HOME/multi.tar.gz -C $HOME/tar one two; cd $proj && ! $S restore $HOME/multi.tar.gz $HOME/multi-out >/dev/null 2>&1 && [[ ! -e $HOME/multi-out ]]"

echo "run (docker shim)"
rshim="$(mktemp -d)"
cat >"$rshim/docker" <<RS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>$rshim/calls
case "\$1" in
  info|image) exit 0 ;;
  volume) echo v ;;
  stop|rm) [[ -f $rshim/pid ]] && kill "\$(cat $rshim/pid)" 2>/dev/null; exit 0 ;;
  run) task="\${*: -1}"; printf '%s\\n' "\$*" >$rshim/argv
       case "\$task" in slow*) echo \$\$ >$rshim/pid; exec sleep 30 ;; fail*) echo no; exit 7 ;; *) echo "Answer: \$task" ;; esac ;;
  *) exit 1 ;;
esac
RS
chmod +x "$rshim/docker"
check "run prints the final message"   bash -c "cd $proj && [[ \$(PATH=$rshim:\$PATH $S run 'say hi' 2>/dev/null) == 'Answer: say hi' ]]"
check "run passes -p --no-approve and hardening" bash -c "tr ' ' '\\n' <$rshim/argv | grep -qx -- -p && grep -q -- '--no-approve' $rshim/argv && grep -q -- '--cap-drop ALL' $rshim/argv && grep -q -- '--rm' $rshim/argv"
check "run applies resource ceilings" bash -c "cd $proj && SAPI_CPUS=1.5 SAPI_MEMORY_MIB=2048 SAPI_PIDS=99 PATH=$rshim:\$PATH $S run x >/dev/null 2>&1 && grep -q -- '--cpus 1.5 --memory 2048m --pids-limit 99' $rshim/argv"
check "run omits ceilings when 0"     bash -c "cd $proj && SAPI_PIDS=0 PATH=$rshim:\$PATH $S run x >/dev/null 2>&1 && ! grep -q -- '--pids-limit' $rshim/argv && ! grep -q -- '--cpus' $rshim/argv"
check "run propagates the exit code"  bash -c "cd $proj; PATH=$rshim:\$PATH $S run fail >/dev/null 2>&1; [[ \$? == 7 ]]"
check "run reads the task from stdin" bash -c "cd $proj && [[ \$(echo piped | PATH=$rshim:\$PATH $S run - 2>/dev/null) == 'Answer: piped' ]]"
check "run --json passes --mode json" bash -c "cd $proj && PATH=$rshim:\$PATH $S run --json x >/dev/null 2>&1 && grep -q -- '--mode json' $rshim/argv"
check "docker args are whitespace-split without host glob expansion" bash -c "cd $proj && touch 'glob=one' && SAPI_DOCKER_ARGS='--label glob=*' PATH=$rshim:\$PATH $S run x >/dev/null 2>&1 && grep -qF -- '--label glob=*' $rshim/argv"
check "run session volumes are labelled for cleanup" bash -c "cd $proj && PATH=$rshim:\$PATH $S run x >/dev/null 2>&1 && grep -q '^volume create .*volume-role=sessions.*-runs-sessions' $rshim/calls"
check "terminating sapi run removes the active container" bash -c "cd $proj; rm -f $rshim/pid $rshim/calls; PATH=$rshim:\$PATH $S run slow-cancel >/dev/null 2>&1 & launcher=\$!; for i in \$(seq 1 100); do [[ -f $rshim/pid ]] && break; sleep 0.1; done; kill -TERM \$launcher; rc=0; wait \$launcher 2>/dev/null || rc=\$?; [[ \$rc == 143 ]] && grep -q '^rm --force .*-run-' $rshim/calls"
check "run --timeout stops and exits 124" bash -c "cd $proj; PATH=$rshim:\$PATH $S run --timeout 1 slow >/dev/null 2>&1; [[ \$? == 124 ]]"
check "run refuses an empty task"     bash -c "cd $proj && ! $S run '  ' 2>/dev/null"
check "--safer run writes a run manifest next to the backup" bash -c "cd $proj && PATH=$rshim:\$PATH $S --safer run 'do it' >/dev/null 2>&1 && m=\$(ls $HOME/.local/share/sapi/backups/*/*.run | tail -1) && grep -qx 'task = do it' \$m && grep -qx 'exit_code = 0' \$m"
rm -rf "$rshim"
rm -rf "$HOME" "$shim"; HOME="$REAL_HOME"; unset SAPI_CONFIG_FILE

echo "hygiene"
check "LICENSE present"              test -f LICENSE
check "README present"               test -f README.md

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
