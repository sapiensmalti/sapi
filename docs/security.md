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
| Docker socket, host PID/network namespaces | not provided |

Running sapi in your home directory intentionally grants your home directory. Running it in `/` is never a safety boundary. **Shared `sapi-config` is one trust domain across projects:** an agent can alter persistent pi settings/extensions and use credentials stored there. For a hostile project, use a separate `SAPI_CONFIG_VOLUME`, no unnecessary `SAPI_ENV`, safer mode, and an egress allowlist.

## Container hardening

The shared container specification uses:

- Agents, pi updates, and shells start as **root (uid/gid 0:0)** on every platform. Dockerfile/runtime user selection is explicit, and the entrypoint verifies actual root credentials. Sapi does not drop the agent to the host user's identity.
- `--cap-drop ALL` plus `CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER SETUID SETGID`. Root retains these capabilities inside the container; `SETPCAP`, `SYS_ADMIN`, `NET_ADMIN`, and `NET_RAW` are not granted. Root is not the same as a host-privileged container.
- `--security-opt no-new-privileges`, so setuid/file-capability execution cannot add privileges.
- `--init`; optional CPU, memory, and pid ceilings.
- No host network/PID namespace, no privileged mode, and no socket mounts **unless the user deliberately overrides the specification** (below).
- In allowlist mode, a read-only sidecar owns a separate network namespace and the agent receives no network capabilities. See [network.md](network.md).

### Agent identity

All managed agent launches and shells use real/effective uid 0 and gid 0. Nonzero `SAPI_UID` / `SAPI_GID` requests are refused. Extra Docker flags cannot replace the final user selection, private cgroup namespace, or root-checking entrypoint. A stopped legacy non-root container is recreated rather than resumed. Already-running containers are not modified retroactively.

On Linux, new workspace files may be root-owned; restrictive modes may prevent host-user reads, edits, or backups. MacOS ownership mapping depends on the Docker provider. Sapi does not silently change host workspace ownership. Container root may deliberately run child commands under other identities; the primary agent/updater/shell is launched as root.

Allowlist exemption is based on the sidecar's cgroup-v2 membership, not Unix uid. Changing an agent child's uid, including to the proxy uid, must not grant exemption. Agents have a private, read-only cgroup hierarchy and no `SYS_ADMIN` to change it; the proxy uses a host cgroup namespace to discover its exact membership. Unsupported kernels and legacy UID-exempt sidecars fail closed. See [network](network.md).

Invalid configuration/environment values still abort before launching Docker resources. The root policy does not relax safety-setting validation. See [configuration](configuration.md#config-file).

## Explicit escape hatches

`SAPI_DOCKER_ARGS` appends arbitrary Docker flags, `SAPI_IMAGE` selects another image, `SAPI_EGRESS_IMAGE` selects another sidecar, and `Dockerfile.extra` executes a user-chosen build. They are intentionally outside the default guarantee: for example, `SAPI_DOCKER_ARGS='--privileged -v /:/host'` defeats isolation. Do not inherit these settings from a project, `.env`, or untrusted shell setup. `SAPI_DOCKER_ARGS` is whitespace-split without shell glob expansion; quoting is not interpreted.

Sapi does not automatically read project-local launcher configuration. Explicitly selecting a project file through a host environment variable is still your trust decision. Headless runs pass pi `--no-approve` to ignore project-local resources; this is not per-tool approval or protection from prompt injection in project content.

## What sapi writes on your host

- `~/.local/bin/sapi` (or `SAPI_INSTALL_DIR`), replaced atomically.
- Optional `~/.config/sapi/config` and user toolchain fragments.
- Optional backups and run manifests under `~/.local/share/sapi/backups` (mode 0600 in 0700 project folders).
- Docker images, containers, and volumes; private temporary directories for backup/diff/restore.
- No sudo, automatic workspace ownership changes, shell-profile edits, launch agents, background daemons, or launcher telemetry. pi and the model provider have their own network behavior and data policies.

`sapi rm` removes managed containers and session volumes, including headless-run volumes. It deliberately keeps the config volume. Very old unlabeled volumes with no owning container may require manual removal.

## Threat model

The default filesystem boundary separates the workspace and Docker volumes from unmounted host files. Backups and the opt-in allowlist address different risks; neither makes arbitrary agent commands harmless. Full network mode can reach any service accessible through Docker's network, including host/LAN services.

It does **not** protect against:

- **Docker/kernel escapes or a malicious Docker daemon.** Containers are not VMs; host Docker access is host-root-equivalent. For hostile workloads use a VM-backed runtime or a separate VM.
- **Damage to the mounted directory.** Use git and [safer mode](recovery.md). Backups are local, unencrypted, and not off-site.
- **Allowed network channels.** Full mode permits exfiltration. Allowlist mode limits destinations by hostname on 80/443 but does not inspect encrypted content; an allowed host remains a channel.
- **Secrets intentionally made available.** `.env` in the workspace, the shared credentials volume, and `SAPI_ENV` values are readable by the agent and may reach the model provider.
- **A compromised upstream or mutable software.** The default starting image is a tested snapshot pinned by digest, but automatic pi updates remain enabled and may select new npm dependencies. Source/custom builds also use mutable upstream inputs. `SAPI_AUTO_UPDATE=0` prevents startup update attempts; it does not make source builds bit-reproducible, prevent deliberate agent changes, or guarantee upstream availability. See [images and builds](images.md).
- **An immutable audit trail.** Agents can modify their session files and settings. A diff compares two tree states; it does not record all actions or establish which process made a change. See [recovery](recovery.md).
- **Host-wide network filtering.** The allowlist applies to the agent's runtime namespace, not Docker pulls, build-time package downloads, or other host processes.

## Supply chain of sapi itself

- The installer defaults to a release tag; `SAPI_REF=main` selects development. Downloads use HTTPS, shebang/syntax validation, and atomic replacement. GitHub/TLS is the authenticity root; a tag is a version pin, not an independent signature.
- `sapi dockerfile` prints the complete effective image definition.
- The agent starting image is digest-pinned and checked against the embedded recipe fingerprint, baked pi-version label, and root-user metadata. Each architecture's exact candidate passes kernel smoke before publication. Runtime updates remain a separate, default-enabled policy.
- The sidecar image is digest-pinned, its source archive checksum-pinned, and its test-only hooks excluded from production builds.
- GitHub Actions are commit-pinned; Rust dependencies are lockfile-pinned and checked with cargo-deny.

## Reporting

Use the [private process in SECURITY.md](../SECURITY.md). Do not disclose a vulnerability in a public issue.
