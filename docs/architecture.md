# Architecture

## Components

| Component | Role |
|---|---|
| `install.sh` | Download, syntax-check, and atomically install the launcher. No Docker installation or privilege escalation. |
| `sapi` | Single-file Bash launcher with the agent Dockerfile and entrypoint embedded. |
| Agent image | Digest-pinned amd64/arm64 starting image: Debian bookworm / Node 24, reviewed pi, git, ripgrep, jq, curl, SSH client, and `uv`/`uvx`. Full-source builds remain available. Python is provisioned by uv, not preinstalled. |
| Entrypoint | Verify actual root identity, set a root environment, optionally update pi, then exec pi or Bash without dropping identity. |
| `egress/` | Optional Rust sidecar for namespace firewall, local DNS responses, and hostname-filtered relays. |

Only the launcher and its Dockerfiles are embedded in one file. The sidecar is a separate image/binary with its own source and tests. Bash orchestrates Docker; Rust handles the long-running network service. No component needs a Docker socket inside the agent container.

## Build identity

The default image is selected by a published digest and checked against the embedded full-recipe fingerprint, starting pi-version label, and declared `0:0` user. Metadata/pull failures stop preparation; there is no silent source fallback.

Packages/fragments normally extend that image. `SAPI_BUILD=1`, a different requested pi version, or `SAPI_REBUILD=1` selects the full embedded source recipe. Custom/source tags use the first 12 hex digits of SHA-256 over the requested pi version and effective recipe; missing images are built, cached images reused. An explicit cached `SAPI_IMAGE` is used as supplied. Build context is empty/private and cleaned on failure, never the workspace.

These are image identities/cache keys, not a complete dependency lock. Pi startup updates remain enabled by default. Source/derived builds also depend on mutable inputs. See [images and builds](images.md).

## Interactive lifecycle

Default base name: `sapi-<sanitized directory name>-<first 8 hex digits of path hash>`. An explicit `sapi NAME` supplies another base. Sapi scans that name, then `NAME-2`, `NAME-3`, and so on:

1. Pull/build/reuse the image. In safer mode, back up before starting the selected agent; other running agents are not stopped.
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

The Dockerfile explicitly sets `USER 0:0`, including after user fragments. The launcher appends `--user 0:0`, a private cgroup namespace, the root-checking entrypoint, and zero identity environment values after extra Docker arguments. Resume requires matching policy/settings and actual Docker `Config.User` of `0:0`. Shell exec also explicitly selects `0:0`.

The entrypoint checks real/effective root credentials and sets `HOME=/root`, `USER=root`, and `LOGNAME=root`. Pi is installed under `/opt/pi`; pi updates, extensions, and the agent all execute as container root. Update failure is logged and startup continues. The launcher skips updates in allowlist mode without `@npm`; Bash shells skip them. Sapi does not chown the host workspace to disguise root-created files. See [security](security.md).

`container_args` produces the shared Bash array of mounts, environment, labels, and hardening flags used by interactive agents, headless tasks, and temporary shells. Config parsing accepts only known keys and does not execute shell code; see [configuration](configuration.md).

- **`run`** uses an ephemeral container, persistent run-session volume, and optional backup/run summary. Its timeout starts at container launch.
- **`shell`** either execs into a running agent or starts a temporary shell. A joining shell inherits the running agent's network/mounts; an ephemeral shell adds the run-session volume if present and has no network unless `--net`.
- **`diff` / `restore`** run on the host, using private temporary staging and standard Unix tools. Restore replaces selected paths individually, with rollback or saved-original preservation on failure.
- **`upgrade`** fetches the current installer, which selects a release tag unless `SAPI_REF` is explicitly supplied. This does not imply installing `main`.

## Allowlist sidecar

The root agent joins the sidecar's network namespace with `--network container:NAME-egress`, but remains in a separate cgroup. Firewall exemptions match only the proxy cgroup, never its uid. The sidecar uses `--cgroupns host`, rejects an ambiguous/root cgroup path, installs default-drop rules, binds listeners, drops its own privileges, and writes a `cgroup-v2` readiness marker on a fresh `/run` tmpfs. The launcher rejects legacy readiness markers. Production images are digest-pinned and exclude test-only bypass flags; local source builds use a checksum-pinned archive.

The runtime allowlist does not cover Docker's build/pull traffic. Enforcement, logging limits, and provider presets are in [network](network.md); backup/session behavior is in [recovery](recovery.md).
