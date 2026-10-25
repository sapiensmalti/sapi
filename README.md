# sapi

[![ci](https://github.com/sapiensmalti/sapi/actions/workflows/ci.yml/badge.svg)](https://github.com/sapiensmalti/sapi/actions/workflows/ci.yml)

**The Super Accessible [pi](https://github.com/badlogic/pi-mono) agent, isolated, and scoped to the directory you invoke it from.**

```sh
curl -fsSL https://raw.githubusercontent.com/sapiensmalti/sapi/main/install.sh | bash
```

Then, in any project:

```sh
sapi
```

That's it. The agent can read and write **this directory**, and nothing else on your machine.

---

## Why

AI coding agents run shell commands. Giving one your whole laptop is a bad trade. `sapi` gives it exactly one directory, a throwaway Linux box to work in, and a persistent place for its login and session history. Everything else stays yours.

- **One file.** `sapi` is a single bash script. The installer copies it to `~/.local/bin`. No sudo, no shell-profile edits, no daemons.
- **One directory.** The only thing mounted from your machine is the directory you run `sapi` from.
- **Your files stay yours.** On Linux the agent runs as *your* uid/gid, so nothing comes out root-owned.
- **Recoverable by construction.** `sapi --safer` takes a complete, checksummed backup before every start — stored where the agent cannot reach it — and refuses to start if it cannot. `sapi diff` shows every path the agent changed; `sapi restore latest --files …` puts any of them back. The sandbox protects everything outside the directory; this protects the directory itself.
- **A Unix command.** `sapi run TASK` runs one headless task: final message on stdout, the agent's exit code, `--timeout`. In a cron job with safer mode, every run leaves a backup, a run manifest and a diff behind — auditable and reversible without the agent's cooperation.
- **Your toolchain, your call.** `sapi config set packages "golang make"` or a `~/.config/sapi/Dockerfile.extra` extends the image; `sapi dockerfile` shows exactly what gets built. User-level only — a repository can never add a build step to your host.
- **Egress allowlist, when you want it.** `sapi config set network allowlist`: a Rust sidecar owns the agent's network namespace — kernel-level redirection, fake DNS (no tunnelling), TLS-SNI and HTTP-Host filtering, connect-by-name. Only the hosts you list, on 80/443; everything else dropped and logged. Off by default.
- **Persistent where it matters.** Credentials and settings live in one Docker volume; each project's sessions in another. Containers are disposable; `sapi` resumes or rebuilds them transparently.
- **Hardened by default.** All Linux capabilities dropped except the few needed to drop privileges; `no-new-privileges`; no Docker socket; no host network; optional cpu/memory/pid ceilings.
- **Always current.** `pi` self-updates on every start. If that fails (offline), it just starts.

## Install

**Requirements:** macOS or Ubuntu/Linux, `curl`, and Docker
([OrbStack](https://orbstack.dev) or Docker Desktop on macOS; `apt-get install docker.io` on Ubuntu).

```sh
curl -fsSL https://raw.githubusercontent.com/sapiensmalti/sapi/main/install.sh | bash
```

Prefer to read before you run? Same thing, two steps:

```sh
curl -fsSL https://raw.githubusercontent.com/sapiensmalti/sapi/main/install.sh -o install.sh
less install.sh && bash install.sh
```

The installer puts one executable at `~/.local/bin/sapi` (override: `SAPI_INSTALL_DIR`). If that directory isn't on your `PATH`, it prints the one line to add. Nothing else is touched.

**Uninstall:** `rm ~/.local/bin/sapi`. Remove containers and sessions with `sapi rm --all` first if you like, and `docker volume rm sapi-config` to forget credentials.

## Use

```
sapi                 start (or resume) an agent in the current directory
sapi NAME            same, with a container name you choose
sapi run TASK        headless: final message on stdout, agent's exit code; --json, --timeout S, '-' for stdin
sapi --safer         back up the directory first; refuse to start if that fails
sapi diff            what changed since the backup (A/M/D per path; --full for hunks)
sapi restore latest --files PATH…   put back just those files · sapi restore latest → whole tree beside the original
sapi backups         list this directory's backups
sapi config          show or set persistent settings
sapi shell           a shell in /pi-sessions (session files) with /pi-config beside it; --net for network
sapi ls              list sapi containers
sapi rm [--all]      remove this directory's containers (or all)
sapi build           build the image without starting
sapi dockerfile      print the embedded Dockerfile
sapi upgrade         upgrade sapi itself
```

First run builds the image (a minute or two). After that, starting is instant.

Run `sapi` twice in the same directory and you get two independent agents (`…`, `…-2`). Detach from a running agent with `Ctrl-P`, `Ctrl-Q`; run `sapi` again to reattach.

### Configuration

All optional, all environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `SAPI_SAFER` | `0` | `1` backs up the directory before every start and aborts if that fails ([details](docs/recovery.md)) |
| `SAPI_BACKUP_DIR` | `~/.local/share/sapi/backups` | where backups go; must be outside the directory |
| `SAPI_BACKUP_KEEP` | `10` | backups kept per directory; `0` keeps all |
| `SAPI_CPUS` / `SAPI_MEMORY_MIB` / `SAPI_PIDS` | unlimited / unlimited / `4096` | resource ceilings for the agent container |
| `SAPI_PACKAGES` | | extra Debian packages baked into the image, e.g. `"golang make"` ([details](docs/toolchain.md)) |
| `SAPI_DOCKERFILE_EXTRA` | `~/.config/sapi/Dockerfile.extra` | Dockerfile fragment appended when the file exists |
| `SAPI_NETWORK` | `full` | `allowlist` restricts egress to `SAPI_ALLOW` on 80/443 ([details](docs/network.md)) |
| `SAPI_ALLOW` | `@providers` | hosts, `*.suffix`, `host:port`, presets `@providers @github @npm @pypi @cargo @go @debian @huggingface` |
| `SAPI_MODEL` | *(pi decides)* | Passed to `pi --model`, e.g. `openrouter/anthropic/claude-sonnet-4.5` |
| `SAPI_PI_VERSION` | `latest` | pi npm version baked into the image |
| `SAPI_AUTO_UPDATE` | `1` | `0` disables `pi update` on container start |
| `SAPI_REBUILD` | `0` | `1` rebuilds the image from scratch (`--no-cache --pull`) |
| `SAPI_UID` / `SAPI_GID` | your uid/gid on Linux; `0` on macOS | user the agent runs as inside the container |
| `SAPI_CONFIG_VOLUME` | `sapi-config` | Docker volume holding pi's config and credentials |
| `SAPI_ENV` | | space-separated host variables to pass in, e.g. `"ANTHROPIC_API_KEY GH_TOKEN"` |
| `SAPI_DOCKER_ARGS` | | extra flags for `docker create` (e.g. `-p 3000:3000`) |

Every setting can also be set once in `~/.config/sapi/config` (`sapi config set safer true`; `sapi config keys` lists them). Precedence: flag > environment > config file > default.

## How it works

```
 your machine                              container (debian + node + pi + uv)
 ┌──────────────────────────┐              ┌────────────────────────────────┐
 │ ~/code/project  ─────────┼─ bind mount ─┼─▶ /workspace   (read/write)    │
 │ volume sapi-config ──────┼──────────────┼─▶ /pi-config   (login, config) │
 │ volume <name>-sessions ──┼──────────────┼─▶ /pi-sessions (history)       │
 └──────────────────────────┘              └────────────────────────────────┘
```

`sapi` hashes its embedded Dockerfile to name the image, so changing the definition (or upgrading `sapi`) naturally produces a fresh image. Containers are labelled with the workspace path, image, and settings; on start, `sapi` resumes a matching stopped container, replaces a stale one, or allocates a new slot if one is already running. Sessions survive all of this because they live in a volume.

More: [architecture](docs/architecture.md) · [security model](docs/security.md) · [recovery: backup · run · diff · restore](docs/recovery.md) · [toolchain](docs/toolchain.md) · [network egress allowlist](docs/network.md) · [troubleshooting](docs/troubleshooting.md)

## Repository

```
sapi             launcher (bash): everything the user runs; embedded Dockerfile and entrypoint
install.sh       installer
egress/          sapi-egress (Rust): the optional network allowlist sidecar
docs/            recovery · toolchain · network · architecture · security · troubleshooting
test/            check.sh (no Docker) · smoke.sh (real Docker, incl. the firewall)
```

## Contributing

The launcher is one readable file and stays that way; anything long-running or security-critical is a small Rust binary with its own tests.

- `sapi` — launcher, embedded Dockerfile and entrypoint
- `install.sh` — installer
- `egress/` — sidecar: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
- `test/check.sh` — lint and unit checks (no Docker needed)
- `test/smoke.sh` — builds the image and exercises it (needs Docker)

Run both before opening a PR. Changes that add dependencies, touch the host outside `~/.local/bin`, or widen the container's access need a very good reason.

## License

[MIT](LICENSE)
