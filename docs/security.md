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

- `--cap-drop ALL` plus only `CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER SETUID SETGID`, needed to repair volume ownership and drop privileges. `SETPCAP` is not granted. On Linux the real-container test verifies **zero effective and permitted capabilities** after the drop.
- `--security-opt no-new-privileges`, so setuid/file-capability execution cannot add privileges.
- `--init`; optional CPU, memory, and pid ceilings.
- No host network/PID namespace, no privileged mode, and no socket mounts **unless the user deliberately overrides the specification** (below).
- In allowlist mode, a read-only sidecar owns a separate network namespace and the agent receives no network capabilities. See [network.md](network.md).

On Linux the agent runs as your uid/gid. On macOS it runs as uid 0 **inside the container**, because Docker Desktop/OrbStack map bind-mount ownership; those remaining container capabilities do not grant host root. The macOS root user still has the listed capabilities inside the container, unlike the dropped Linux process.

### Root agents and allowlisting

UID-0 agents retain identity-changing capabilities, including `SETUID` and `SETGID`. This includes the macOS default and Linux invocations as root. The sidecar exempts its own uid for upstream traffic; an agent able to adopt that uid can enter the exemption. **Do not treat allowlist mode as a reliable boundary against hostile code in this configuration.** `no-new-privileges` does not prevent that identity change.

Capability-free non-root agents are the intended isolation case. Changing `SAPI_UID` / `SAPI_GID` requires checking workspace/volume permissions with your Docker provider; it is not a universally verified macOS workaround. Existing firewall smoke probes use `--cap-drop ALL`, so their success alone does not validate the root-agent capability set.

### Invalid environment overrides

Malformed environment settings are not reliably fail-closed: validation can print an error while the launcher continues with an empty effective value. In particular, an invalid `SAPI_SAFER` can bypass a saved `safer = true`. An explicit valid `--safer` flag takes precedence. See [configuration](configuration.md#config-file); a successful command exit alone is not proof that every environment override validated.

## Explicit escape hatches

`SAPI_DOCKER_ARGS` appends arbitrary Docker flags, `SAPI_IMAGE` selects another image, `SAPI_EGRESS_IMAGE` selects another sidecar, and `Dockerfile.extra` executes a user-chosen build. They are intentionally outside the default guarantee: for example, `SAPI_DOCKER_ARGS='--privileged -v /:/host'` defeats isolation. Do not inherit these settings from a project, `.env`, or untrusted shell setup. `SAPI_DOCKER_ARGS` is whitespace-split without shell glob expansion; quoting is not interpreted.

Sapi does not automatically read project-local launcher configuration. Explicitly selecting a project file through a host environment variable is still your trust decision. Headless runs pass pi `--no-approve` to ignore project-local resources; this is not per-tool approval or protection from prompt injection in project content.

## What sapi writes on your host

- `~/.local/bin/sapi` (or `SAPI_INSTALL_DIR`), replaced atomically.
- Optional `~/.config/sapi/config` and user toolchain fragments.
- Optional backups and run manifests under `~/.local/share/sapi/backups` (mode 0600 in 0700 project folders).
- Docker images, containers, and volumes; private temporary directories for backup/diff/restore.
- No sudo, shell-profile edits, launch agents, background daemons, or launcher telemetry. pi and the model provider have their own network behavior and data policies.

`sapi rm` removes managed containers and session volumes, including headless-run volumes. It deliberately keeps the config volume. Very old unlabeled volumes with no owning container may require manual removal.

## Threat model

The default filesystem boundary separates the workspace and Docker volumes from unmounted host files. Backups and the opt-in allowlist address different risks; neither makes arbitrary agent commands harmless. Full network mode can reach any service accessible through Docker's network, including host/LAN services.

It does **not** protect against:

- **Docker/kernel escapes or a malicious Docker daemon.** Containers are not VMs; host Docker access is host-root-equivalent. For hostile workloads use a VM-backed runtime or a separate VM.
- **Damage to the mounted directory.** Use git and [safer mode](recovery.md). Backups are local, unencrypted, and not off-site.
- **Allowed network channels.** Full mode permits exfiltration. Allowlist mode limits destinations by hostname on 80/443 but does not inspect encrypted content; an allowed host remains a channel.
- **Secrets intentionally made available.** `.env` in the workspace, the shared credentials volume, and `SAPI_ENV` values are readable by the agent and may reach the model provider.
- **A compromised upstream or mutable build inputs.** npm, apt, base-image tags, and pi's default self-update can change independently of sapi. Pinning `SAPI_PI_VERSION` does not lock transitive npm dependencies. `SAPI_AUTO_UPDATE=0` prevents startup update attempts, but neither setting makes builds bit-reproducible or guarantees upstream availability. Use reviewed locks, mirrors, and image digests for stronger control.
- **An immutable audit trail.** Agents can modify their session files and settings. A diff compares two tree states; it does not record all actions or establish which process made a change. See [recovery](recovery.md).
- **Host-wide network filtering.** The allowlist applies to the agent's runtime namespace, not Docker pulls, build-time package downloads, or other host processes.

## Supply chain of sapi itself

- The installer defaults to a release tag; `SAPI_REF=main` selects development. Downloads use HTTPS, shebang/syntax validation, and atomic replacement. GitHub/TLS is the authenticity root; a tag is a version pin, not an independent signature.
- `sapi dockerfile` prints the complete effective image definition.
- The sidecar image is digest-pinned, its source archive checksum-pinned, and its test-only hooks excluded from production builds.
- GitHub Actions are commit-pinned; Rust dependencies are lockfile-pinned and checked with cargo-deny.

## Reporting

Use the [private process in SECURITY.md](../SECURITY.md). Do not disclose a vulnerability in a public issue.
