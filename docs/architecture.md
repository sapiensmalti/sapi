# Architecture

## Components

| Component | Role |
|---|---|
| `install.sh` | Download, syntax-check, and atomically install the launcher. No Docker installation or privilege escalation. |
| `sapi` | Single-file Bash launcher with the agent Dockerfile and entrypoint embedded. |
| Agent image | Debian bookworm / Node 24, pi from npm, git, ripgrep, jq, curl, SSH client, and `uv`/`uvx`. Python can be provisioned by uv; it is not preinstalled by sapi. |
| Entrypoint | Repair volume ownership, drop uid/capabilities, then attempt pi update and run pi or Bash. |
| `egress/` | Optional Rust sidecar for namespace firewall, local DNS responses, and hostname-filtered relays. |

Only the launcher and its Dockerfiles are embedded in one file. The sidecar is a separate image/binary with its own source and tests. Bash orchestrates Docker; Rust handles the long-running network service. No component needs a Docker socket inside the agent container.

## Build identity

The agent image tag is `sapi:<first 12 hex digits of SHA-256(pi version string + effective Dockerfile)>`. The effective Dockerfile includes configured packages and the user's fragment. Build context is an empty temporary directory, not the workspace.

A missing image is built; an existing tag is reused. `SAPI_REBUILD=1` forces `--no-cache --pull`. A launcher upgrade does not necessarily change the image tag. Mutable upstream inputs can produce different bytes from the same build definition; this hash is not a reproducibility guarantee. See [security](security.md#threat-model).

## Interactive lifecycle

Default base name: `sapi-<sanitized directory name>-<first 8 hex digits of path hash>`. An explicit `sapi NAME` supplies another base. Sapi scans that name, then `NAME-2`, `NAME-3`, and so on:

1. Build/reuse the image. In safer mode, back up before starting the selected agent; other running agents are not stopped.
2. Skip a name owned by another workspace or a running container.
3. Resume a stopped container only if its image ID, sapi version, and persisted settings match.
4. Otherwise replace the stopped container, keeping its session volume; create in the first available slot.
5. In allowlist mode, make the sidecar ready before starting the agent. If a stopped agent's sidecar is gone, recreate the pair.

The settings signature covers network, model, uid/gid, update mode, resource limits, config volume, environment names, and extra Docker arguments. Containers using `SAPI_ENV` always refresh; values supplied through it are not hashed. Arbitrary extra Docker arguments are included in the signature.

Sapi starts pi with `--continue`. This continues the slot's most recent stored session when available; it does not attach to an already running container. Use `docker attach NAME` for that. Ctrl-P, Ctrl-Q detaches without stopping.

## Storage

| Host/Docker resource | Container path | Lifetime |
|---|---|---|
| Workspace bind mount | `/workspace` | Host files; never removed by `sapi rm` |
| `sapi-config` or selected config volume | `/pi-config` | Shared credentials, settings, extensions, gitconfig; kept by `sapi rm` |
| `NAME-sessions` | `/pi-sessions` | Per interactive slot; removed by `sapi rm` |
| `<default-base>-runs-sessions` | `/pi-sessions` during headless runs | Shared by this workspace's headless tasks; removed by `sapi rm` |
| Backup files outside the workspace | Not mounted | Kept according to `backup_keep`, not removed by `sapi rm` |

`PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` point pi to those volumes. `GIT_CONFIG_GLOBAL` points to `/pi-config/gitconfig`. Workspace and volume contents survive container replacement; changes made only in the container's writable layer do not. Images are retained until explicitly removed.

## Entrypoint and other commands

The privileged bootstrap repairs ownership of config/session/home directories, then `setpriv` switches to a non-root uid/gid, clears supplementary groups and inheritable/ambient capabilities, and sets no-new-privileges. Both Linux and macOS default to the host uid/gid. UID 0 is refused, including at the image entrypoint.

Pi is installed under `/opt/pi`. Update-enabled agents also receive ownership of that npm prefix; trusted bootstrap files remain root-owned. Only after privilege dropping does the entrypoint run `pi update self --no-approve`, with failure logged and startup continued. The launcher skips it in allowlist mode without `@npm`; Bash shells skip it. No pi code or extensions execute during privileged setup. See [security](security.md).

`container_args` produces the shared Bash array of mounts, environment, labels, and hardening flags used by interactive agents, headless tasks, and temporary shells. Config parsing accepts only known keys and does not execute shell code; see [configuration](configuration.md).

- **`run`** uses an ephemeral container, persistent run-session volume, and optional backup/run summary. Its timeout starts at container launch.
- **`shell`** either execs into a running agent or starts a temporary shell. A joining shell inherits the running agent's network/mounts; an ephemeral shell adds the run-session volume if present and has no network unless `--net`.
- **`diff` / `restore`** run on the host, using private temporary staging and standard Unix tools. Restore replaces selected paths individually, with rollback or saved-original preservation on failure.
- **`upgrade`** fetches the current installer, which selects a release tag unless `SAPI_REF` is explicitly supplied. This does not imply installing `main`.

## Allowlist sidecar

The agent joins the sidecar's network namespace with `--network container:NAME-egress`. The sidecar installs default-drop rules, binds its listeners, drops privileges, then writes readiness on a fresh `/run` tmpfs. The launcher waits for that file. Production images are digest-pinned and exclude test-only bypass flags; local source builds use a checksum-pinned archive.

The runtime allowlist does not cover Docker's build/pull traffic. Enforcement, logging limits, and provider presets are in [network](network.md); backup/session behavior is in [recovery](recovery.md).
