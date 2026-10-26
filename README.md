# sapi

[![ci](https://github.com/sapiensmalti/sapi/actions/workflows/ci.yml/badge.svg)](https://github.com/sapiensmalti/sapi/actions/workflows/ci.yml)

[pi](https://github.com/earendil-works/pi) in Docker, scoped to the directory you run it from.

sapi mounts the current directory at `/workspace`. Credentials, settings, and session history live in Docker volumes. It does not mount your home directory, SSH agent, or Docker socket by default.

**The workspace remains writable and network access is unrestricted by default.** Credentials and pi settings are shared across projects unless you choose a separate config volume. Read the [security model](docs/security.md) before running untrusted code.

## Install and start

Requirements: macOS or Linux, Bash, `curl`, standard Unix tools, and Docker 23+ with Buildx. Debian 12+ is the documented Linux setup; the launcher also works on other distributions.

- **macOS:** [OrbStack](https://orbstack.dev) or Docker Desktop.
- **Debian:** follow [Docker's installation guide](https://docs.docker.com/engine/install/debian/). The distribution's `docker.io` package may be too old.
- Check that `docker info` works as your normal user. Docker group membership grants root-equivalent host access.

```sh
curl -fsSL https://raw.githubusercontent.com/sapiensmalti/sapi/main/install.sh | bash
cd /path/to/project
sapi
```

The installer copies one executable to `~/.local/bin`, without sudo or shell-profile edits. If needed, add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile. You can [read the installer](install.sh) before running it.

First start builds a Linux image and needs network access; build time depends on the runtime and downloads. Agent starts also attempt to update pi by default. Inside pi, use `/login` to configure a provider. Alternatively, pass an already-exported API key by name:

```sh
SAPI_ENV=OPENROUTER_API_KEY sapi
```

Pi handles model selection and authentication. Model usage is billed by your provider.

## Work and recover

```sh
sapi --safer                         # back up this directory before starting
sapi diff                            # compare the current tree with its latest backup
sapi diff --full                      # include file-content hunks
sapi restore latest --files src/main.rs
sapi restore latest                  # restore the whole backup beside the original
```

Safer mode is opt-in. Enable it persistently with `sapi config set safer true`. Backups include everything, including `.git`, build output, and secrets; they need space outside the workspace. Stop agents and other writers before comparing or restoring. Selecting a directory with `restore --files` replaces it, including removing later additions. See [recovery](docs/recovery.md).

For an unattended task:

```sh
sapi --safer run --timeout 900 "Run the tests and fix the failures."
```

The final message goes to stdout; sapi diagnostics go to stderr. `--json` returns pi's event stream. The timeout begins at container launch, not during the preceding image build or backup.

## Agents and shells

| Command | Behavior |
|---|---|
| `sapi [NAME]` | Resume a compatible stopped agent, or create one. If that name is running, use the next numbered slot. |
| `sapi ls` | List managed containers, including egress sidecars. |
| `docker attach NAME` | Reattach to a running agent listed by `sapi ls`. |
| `sapi shell [NAME]` | Open Bash in `/pi-sessions`: join a running agent, or create a temporary shell. |
| `sapi shell [NAME] --net` | Allow network in a temporary shell; a shell joining a running agent always inherits its network. |
| `sapi netlog [NAME]` | Print available egress-sidecar logs when using the allowlist. |
| `sapi rm` | **Stop and remove** this directory's managed containers and session volumes. |
| `sapi rm --all` | The same for all managed projects. Config volumes, backups, and images remain. |

Detach with **Ctrl-P, Ctrl-Q**. This leaves the agent running; running `sapi` again creates another agent rather than reattaching. A temporary shell has no network unless `--net`; it still mounts the workspace and credentials. Details: [recovery and sessions](docs/recovery.md#sessions-and-shells).

## Configure

```sh
sapi config                          # effective persistent settings and their sources
sapi config keys                     # settings accepted by the config file
sapi config set packages "golang make"
sapi config set network allowlist
sapi config set allow "@providers @github @npm"
```

Config-file settings use flag > environment > config > default precedence. Other controls, such as `SAPI_MODEL`, `SAPI_PI_VERSION`, and `SAPI_ENV`, are environment-only. See the [configuration reference](docs/configuration.md).

- [Toolchains](docs/toolchain.md): extra Debian packages and user Dockerfile fragments.
- [Network allowlist](docs/network.md): hostname filtering on ports 80/443; off by default. Read the [root-agent limitation](docs/security.md#root-agents-and-allowlisting) before relying on it.
- `sapi dockerfile`: print the effective Dockerfile, including customizations.
- `sapi build`: build or reuse the image without starting an agent.
- `sapi help`: command reference.

## Upgrade and remove

`sapi upgrade` replaces the launcher using the release selected by the current installer. **Changes on `main` may not be released yet.** Pi's own update is separate. See [version controls](docs/configuration.md#versions-and-installation) for release pins and development installs.

To uninstall, remove `~/.local/bin/sapi` (or your chosen install path). Before doing so, optionally run `sapi rm --all` to delete managed containers and session history, and `docker volume rm sapi-config` to delete the default shared credentials/settings volume. Backups and images are not removed automatically.

## Development

The Bash launcher embeds the agent Dockerfile and entrypoint; `egress/` contains the optional Rust sidecar. See [architecture](docs/architecture.md).

- `test/check.sh`: lint and launcher tests, including `bash test/recovery.sh` for failure paths and concurrency. No Docker required.
- `test/smoke.sh`: real Docker builds, ownership, recovery, and firewall checks.
- `egress/`: formatting, strict clippy, tests, and cargo-deny; commands are in [CI](.github/workflows/ci.yml).

CI checks Debian 12/13 userspaces and Linux/macOS launchers. Docker smoke tests run on Linux and on macOS with Colima/QEMU; this is not coverage of every Docker provider or a native Debian Docker host. Run the relevant checks before proposing a change; do not widen host access to make a test pass.

[Troubleshooting](docs/troubleshooting.md) · [Security reporting](SECURITY.md) · [Changelog](CHANGELOG.md) · [MIT license](LICENSE)
