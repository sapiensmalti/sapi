# Security model

sapi lets an AI agent run arbitrary commands **against one directory** without giving it the rest of your host filesystem. This page defines the boundary and its exceptions; it is not a claim that containers are VMs.

## What the agent can reach

| Resource | Access |
|---|---|
| The directory you ran `sapi` in, recursively | read / write |
| `sapi-config` volume: pi credentials, settings, extensions, gitconfig | read / write |
| Its interactive or headless-run sessions volume | read / write |
| Network | full by default; opt-in [allowlist](network.md) |
| Other host files, host environment, SSH agent, cloud credentials | not mounted or passed by default |
| Docker socket, host PID/network namespaces, other containers | not provided |

Running sapi in your home directory intentionally grants your home directory. Running it in `/` is never a safety boundary. **Shared `sapi-config` is one trust domain across projects:** an agent can alter persistent pi settings/extensions and use credentials stored there. For a hostile project, use a separate `SAPI_CONFIG_VOLUME`, no unnecessary `SAPI_ENV`, safer mode, and an egress allowlist.

## Container hardening

The shared container specification uses:

- `--cap-drop ALL` plus only `CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER SETUID SETGID`, needed to repair volume ownership and drop privileges. `SETPCAP` is not granted. On Linux the real-container test verifies **zero effective and permitted capabilities** after the drop.
- `--security-opt no-new-privileges`, so setuid/file-capability execution cannot add privileges.
- `--init`; optional CPU, memory, and pid ceilings.
- No host network/PID namespace, no privileged mode, and no socket mounts **unless the user deliberately overrides the specification** (below).
- In allowlist mode, a read-only sidecar owns a separate network namespace and the agent receives no network capabilities. See [network.md](network.md).

On Linux the agent runs as your uid/gid. On macOS it runs as uid 0 **inside the container**, because Docker Desktop/OrbStack map bind-mount ownership; those remaining container capabilities do not grant host root. The macOS root user still has the listed capabilities inside the container, unlike the dropped Linux process.

## Explicit escape hatches

`SAPI_DOCKER_ARGS` appends arbitrary Docker flags, `SAPI_IMAGE` selects another image, `SAPI_EGRESS_IMAGE` selects another sidecar, and `Dockerfile.extra` executes a user-chosen build. They are intentionally outside the default guarantee: for example, `SAPI_DOCKER_ARGS='--privileged -v /:/host'` defeats isolation. Do not inherit these settings from a project, `.env`, or untrusted shell setup. `SAPI_DOCKER_ARGS` is whitespace-split without shell glob expansion; quoting is not interpreted.

Project files cannot configure these options. pi's headless mode also uses `--no-approve` so project-local pi extensions are not automatically trusted.

## What sapi writes on your host

- `~/.local/bin/sapi` (or `SAPI_INSTALL_DIR`), replaced atomically.
- Optional `~/.config/sapi/config` and user toolchain fragments.
- Optional backups and run manifests under `~/.local/share/sapi/backups` (mode 0600 in 0700 project folders).
- Docker images, containers, and volumes; private temporary directories for backup/diff/restore.
- No sudo, shell-profile edits, launch agents, background daemons, or launcher telemetry. pi and the model provider have their own network behavior and data policies.

`sapi rm` removes managed containers and session volumes, including headless-run volumes. It deliberately keeps the config volume. Very old unlabeled volumes with no owning container may require manual removal.

## Threat model, honestly

sapi is designed against an agent that is careless or prompt-injected: destructive commands, unintended reads, leaked environment variables, and disallowed network destinations stay inside their respective boundaries.

It does **not** protect against:

- **Docker/kernel escapes or a malicious Docker daemon.** Containers are not VMs; host Docker access is host-root-equivalent. For hostile workloads use a VM-backed runtime or a separate VM.
- **Damage to the mounted directory.** Use git and [safer mode](recovery.md). Backups are local, unencrypted, and not off-site.
- **Allowed network channels.** Full mode permits exfiltration. Allowlist mode limits destinations by hostname on 80/443 but does not inspect encrypted content; an allowed host remains a channel.
- **Secrets intentionally made available.** `.env` in the workspace, the shared credentials volume, and `SAPI_ENV` values are readable by the agent and may reach the model provider.
- **A compromised upstream or mutable build inputs.** npm, apt, base-image tags, and pi's default self-update can change independently of sapi. `SAPI_AUTO_UPDATE=0` and a pinned `SAPI_PI_VERSION` reduce one input but **do not make builds bit-reproducible** while base images and package repositories remain mutable. Use reviewed internal mirrors/digests for that requirement.

## Supply chain of sapi itself

- The installer defaults to a release tag; `SAPI_REF=main` selects development. Downloads use HTTPS, shebang/syntax validation, and atomic replacement. GitHub/TLS is the authenticity root; a tag is a version pin, not an independent signature.
- `sapi dockerfile` prints the complete effective image definition.
- The sidecar image is digest-pinned, its source archive checksum-pinned, and its test-only hooks excluded from production builds.
- GitHub Actions are commit-pinned; Rust dependencies are lockfile-pinned and checked with cargo-deny.

## Reporting

Use the [private process in SECURITY.md](../SECURITY.md). Do not disclose a vulnerability in a public issue.
