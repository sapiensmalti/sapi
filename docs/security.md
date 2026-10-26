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

- `--cap-drop ALL` plus only `CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER SETUID SETGID`, used only for ownership repair and privilege dropping. `SETPCAP` is not granted. The production entrypoint drops to a non-root uid, clears supplementary groups and inheritable/ambient capabilities, and sets `no-new-privileges` before running any pi code, including self-update. Kernel smoke probes check zero capabilities and failed root/proxy-uid adoption through the real launcher on both Linux and macOS.
- `--security-opt no-new-privileges`, so setuid/file-capability execution cannot add privileges.
- `--init`; optional CPU, memory, and pid ceilings.
- No host network/PID namespace, no privileged mode, and no socket mounts **unless the user deliberately overrides the specification** (below).
- In allowlist mode, a read-only sidecar owns a separate network namespace and the agent receives no network capabilities. See [network.md](network.md).

### Agent identity

Both Linux and macOS default to the invoking user's numeric uid/gid. Agent and shell commands refuse uid 0; an explicitly selected identity must have workspace access. Host root can build images or manage backups, but must select a non-root identity to launch an agent. Sapi does not change workspace ownership automatically.

The proxy's uid is exempt from its firewall, so an agent must not be able to adopt it. Rejecting an initial uid collision alone is insufficient: the production entrypoint also drops identity-changing capabilities before running pi or its updater. Successful identity changes must remain impossible after exec, not just at initial startup.

Invalid configuration and environment values abort before launching Docker resources. This includes malformed safety booleans and zero-padded root/proxy identities. See [configuration](configuration.md#config-file).

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
