# Troubleshooting

**`sapi: docker not found`**
Install Docker 23+ with Buildx. macOS: `brew install orbstack` (or Docker Desktop). Debian: follow [Docker's installation guide](https://docs.docker.com/engine/install/debian/); the distribution's `docker.io` package may be too old.

**`sapi: Docker is not running or you lack permission`**
macOS: start OrbStack / Docker Desktop (sapi tries to do this for you).
Linux: `sudo usermod -aG docker "$USER"`, then log out and back in. Check with `docker info`.

**`sapi: an interactive terminal is required`**
sapi attaches a TUI; run it from a real terminal, not from a script or a pipe.

**`sapi: command not found` after install**
`~/.local/bin` is not on your `PATH`. Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile, or run `~/.local/bin/sapi`.

**The image build fails on `# syntax=docker/dockerfile:1` or `COPY <<EOF`**
Your Docker is too old for BuildKit heredocs. Upgrade Docker (≥ 23) or install `docker-buildx`.

**Files created by the agent are owned by root (Linux)**
You're on an old sapi or set `SAPI_UID=0`. Fix existing files once with `sudo chown -R "$USER:$USER" .`; new files will be yours.

**Permission denied writing to `/workspace` on macOS**
Make sure the directory is inside Docker Desktop's "File sharing" list (OrbStack shares everything by default).

**I have two agents running and want the first one**
`sapi ls` shows them. Attach to a specific one with `docker attach <name>`; `sapi shell <name>` gives you a bash inside it.

**I want to start fresh in this directory**
`sapi rm` removes this directory's containers and their session volumes. Credentials are kept.

**I want to log in again / use another provider**
Inside the agent, run `/login` (pi's own flow). Credentials live in the `sapi-config` volume and are shared by every project.

**Migrating from the original `run-pi` launcher**
Your credentials are in the old `pi-coding-agent-config` volume. Copy them once:

```sh
docker volume create sapi-config
docker run --rm -v pi-coding-agent-config:/from -v sapi-config:/to alpine cp -a /from/. /to/
```

Or keep using the old volume: `export SAPI_CONFIG_VOLUME=pi-coding-agent-config`.

**Rebuild everything**
`SAPI_REBUILD=1 sapi` pulls fresh base images and rebuilds without cache.

**`git commit` inside the agent fails with "Please tell me who you are"**
Set your identity once; it is stored in the config volume and survives container rebuilds:
`git config --global user.name "You" && git config --global user.email you@example.com`
(run it from `sapi shell`, or ask the agent to).

**`git push` / API calls need a token**
Nothing from your host environment is passed in by default. Opt in per variable:
`SAPI_ENV="GH_TOKEN ANTHROPIC_API_KEY" sapi`. Only pass what the task needs.

**`sapi: backup: … is inside …`**
You ran sapi in a directory that contains the backup folder (for example your home directory). Point `SAPI_BACKUP_DIR` or `backup_dir` somewhere outside it.

**`sapi: backup: not enough space`**
The destination has less free space than the directory is large. Free space, or set `backup_dir` to another volume. Backups are never skipped silently in safer mode.

**`sapi: unknown setting` on start**
A typo or invalid value in `~/.config/sapi/config`. `sapi config keys` lists every supported key and type; `sapi config path` prints the file. Comments must occupy a whole line; elsewhere `#` is literal.

**Backups are slow or large**
They include everything, by design. Keep build output and `node_modules` out of directories you run sapi in, or accept the cost. `backup_keep` bounds how many are kept.

**`sapi: backup: another backup … is in progress`**
Another sapi process is archiving the same directory; wait for it. A lock with a known-dead owner is recovered automatically. Never delete a lock whose pid is still running.

**`sapi: backup: incomplete lock …` / `lock recovery busy or interrupted`**
Retry first: another process may still be publishing its PID or recovering a stale lock. If the error persists, stop all backups for that project and inspect the printed `.backup.lock` / `.backup.reap` paths. Only after confirming no backup is running, remove the lock's `pid` file if present and remove the empty lock/recovery directories with `rmdir`. Do not recursively delete their parent: that is where the backups live.

**`sapi: restore: rollback incomplete; original preserved at …`**
The swap failed or was interrupted and the original could not safely be put back. Stop other writers, inspect the printed `old` path and the intended destination, then move the original back when safe. Do not remove `.sapi-restore.*` until its contents are recovered.

**A directory restore removed a new file**
`restore --files DIR` replaces the selected directory exactly as it was in the backup; additions beneath it are removed. Restore individual files when you need a merge, or whole-tree restore beside the original and compare first.

**Where are the session files?**
`sapi shell` puts you in `/pi-sessions` (interactive) with `/pi-sessions-runs` (headless runs) and `/pi-config` beside it. From the host, the Docker volumes are `sapi-<dir>-<hash>-sessions`, `…-runs-sessions` and `sapi-config`.

**Still stuck**
Run `sapi dockerfile`, `sapi config show`, and `docker info`; open an issue with the output and your OS (redact credentials and personal paths). Security findings go through [SECURITY.md](../SECURITY.md), not a public issue.

