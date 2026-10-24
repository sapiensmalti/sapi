# sapi

**The [pi](https://github.com/badlogic/pi-mono) coding agent, isolated in Docker, scoped to the directory you run it from.**

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
- **Persistent where it matters.** Credentials and settings live in one Docker volume; each project's sessions in another. Containers are disposable; `sapi` resumes or rebuilds them transparently.
- **Hardened by default.** All Linux capabilities dropped except the few needed to drop privileges; `no-new-privileges`; no Docker socket; no host network.
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
sapi ls              list sapi containers
sapi rm [--all]      remove this directory's containers (or all)
sapi shell [NAME]    bash inside the running container
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
| `SAPI_MODEL` | *(pi decides)* | Passed to `pi --model`, e.g. `openrouter/anthropic/claude-sonnet-4.5` |
| `SAPI_PI_VERSION` | `latest` | pi npm version baked into the image |
| `SAPI_AUTO_UPDATE` | `1` | `0` disables `pi update` on container start |
| `SAPI_REBUILD` | `0` | `1` rebuilds the image from scratch (`--no-cache --pull`) |
| `SAPI_UID` / `SAPI_GID` | your uid/gid on Linux; `0` on macOS | user the agent runs as inside the container |
| `SAPI_CONFIG_VOLUME` | `sapi-config` | Docker volume holding pi's config and credentials |
| `SAPI_DOCKER_ARGS` | | extra flags for `docker create` (e.g. `-p 3000:3000`) |

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

More: [architecture](docs/architecture.md) · [security model](docs/security.md) · [troubleshooting](docs/troubleshooting.md)

## Contributing

The whole project is two scripts. Keep it that way.

- `sapi` — launcher, embedded Dockerfile and entrypoint
- `install.sh` — installer
- `test/check.sh` — lint and unit checks (no Docker needed)
- `test/smoke.sh` — builds the image and exercises it (needs Docker)

Run both before opening a PR. Changes that add dependencies, touch the host outside `~/.local/bin`, or widen the container's access need a very good reason.

## License

[MIT](LICENSE)
