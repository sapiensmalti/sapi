# Troubleshooting

## Installation and startup

**`sapi: command not found` after installing**
Run `~/.local/bin/sapi`, or add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile. If you used `SAPI_INSTALL_DIR`, use that path instead.

**Docker is missing or the build rejects heredoc syntax**
Use Docker 23+ with Buildx. On macOS, install [OrbStack](https://orbstack.dev) or Docker Desktop. On Debian, follow [Docker's installation guide](https://docs.docker.com/engine/install/debian/); the distribution's `docker.io` may be too old.

**Docker is not running, or permission is denied**
Check `docker info`. Start your macOS Docker provider; sapi attempts to open OrbStack or Docker Desktop automatically. On Debian, ensure the daemon is running and your user has access. `sudo usermod -aG docker "$USER"` requires logging out/in and grants root-equivalent host access. Do not run sapi with sudo merely to bypass the error.

**An interactive terminal is required**
`sapi` and `sapi shell` need a terminal. For scripts, pipes, or cron, use `sapi run TASK` or pipe a task to `sapi run -`.

**Startup is slow, or npm/apt returns a download error**
The first build downloads base images and packages; pi also attempts a startup update by default. A registry can advertise a version before its tarball is available. Check the failing URL/service before retrying; repeated clean builds do not fix a missing upstream artifact. `SAPI_AUTO_UPDATE=0` skips the startup update, not the initial build. Version pins and limits are in [configuration](configuration.md#versions-and-installation).

**I need a clean image build**
`SAPI_REBUILD=1 sapi build` pulls base images and rebuilds without cache. It does not clear credentials, session volumes, or old images.

## Agents and access

**I detached and want the same running agent**
Use `sapi ls`, then `docker attach NAME` for the agent, not its `-egress` sidecar. Ctrl-P, Ctrl-Q detaches without stopping. Running `sapi` or `sapi NAME` while that name is running allocates another numbered slot.

**I want a shell, not the agent UI**
`sapi shell NAME` opens Bash in `/pi-sessions`. It inherits a running agent's network; only temporary shells default to no network. A joining shell does not add `/pi-sessions-runs`. See [sessions and shells](recovery.md#sessions-and-shells).

**I want a new conversation / a clean project agent**
Pi's `/new` starts a conversation without deleting stored history. `sapi rm` instead stops/removes this workspace's managed containers and deletes their session volumes, including headless history; it keeps config volumes, workspace files, backups, and images. `sapi rm --all` applies across all managed projects.

**I need another provider or separate credentials**
Use `/login` in pi, or pass a provider's exported API-key variable with `SAPI_ENV`. Credentials/settings are shared through `sapi-config` by default. Use the same `SAPI_CONFIG_VOLUME=NAME` on subsequent starts and shells for a [separate trust domain](configuration.md#environment-only-controls).

**`git push` or API calls need credentials**
Pass exported variable names, for example `SAPI_ENV="GH_TOKEN ANTHROPIC_API_KEY" sapi`. This does not configure Git authentication, install `gh`, or forward your host SSH agent. Set up your chosen HTTPS credential helper inside the container; avoid embedding tokens in Git URLs or logs. SSH transport is unavailable in allowlist mode.

**`git commit` needs an identity**
Inside `sapi shell`, run `git config --global user.name "You"` and `git config --global user.email you@example.com`. The global Git config lives in the shared config volume.

**Linux files were created with unexpected ownership**
Check `SAPI_UID` / `SAPI_GID` and whether sapi was run as root. Defaults use the invoking Linux user's uid/gid. Repair only affected paths with the intended numeric uid/gid; do not blindly change ownership of a shared project.

**macOS cannot write `/workspace`**
Check the Docker provider's file-sharing permissions for this directory. Sapi uses uid 0 inside macOS containers; host ownership mapping belongs to the provider, not to that container uid.

## Configuration, network, and recovery

**A config value is rejected**
`sapi config keys` lists supported keys; `sapi config path` prints the selected file. Values are not shell-quoted or expanded. Comments must occupy a whole line; elsewhere `#` is literal. Options such as `SAPI_MODEL` are environment-only. See [configuration](configuration.md).

**A host is blocked, or the network log is empty**
Presets may need extra provider/login/CDN hosts. Use `sapi netlog NAME` for the relevant sidecar. TLS/HTTP allow records appear when connections end; firewall-dropped packets do not get JSON records. Port 22 and other non-80/443 ports remain blocked. See [network limits](network.md#operational-limits).

**The backup path is inside the workspace / space is insufficient**
Choose `backup_dir` outside the workspace, with room for a complete archive. Backups include `.git`, build outputs, and secrets. `backup_keep` bounds archive count, not disk use. A failed backup prevents the selected agent start.

**A backup is already running / its lock is incomplete**
Retry first. A live creator may be publishing ownership or recovering a stale lock. Known-dead owners recover automatically. If the error persists, stop all backups for that project and inspect the printed `.backup.lock` / `.backup.reap` paths. Only after confirming no backup is running, remove the lock's `pid` if present and use `rmdir` for the empty lock/recovery directories. Never recursively delete their parent: it contains backups.

**Restore reports `original preserved at …`**
Stop other writers. Inspect the printed `old` path and intended destination, then move the original back when safe. Do not delete `.sapi-restore.*` until its contents are recovered. A multi-path restore is not one transaction; earlier successful paths remain restored.

**Restoring a directory removed a new file**
`restore --files DIR` replaces that directory exactly. Restore individual files for selective changes, or restore the whole backup beside the original and compare. See [restore](recovery.md#restore).

## Legacy credentials and reporting

The original `run-pi` launcher used `pi-coding-agent-config`. To keep using that volume, set `SAPI_CONFIG_VOLUME=pi-coding-agent-config`. To copy it into the default volume, stop agents using either volume first:

```sh
docker volume create sapi-config
docker run --rm -v pi-coding-agent-config:/from:ro -v sapi-config:/to alpine cp -a /from/. /to/
```

For other failures, collect `sapi version`, `sapi config show`, `docker info`, your OS/provider, and the failing command. Review/redact outputs before reporting: workspace paths, custom Dockerfile contents, logs, and environment values may be sensitive. Security findings use the [private reporting process](../SECURITY.md), not public reproduction details.
