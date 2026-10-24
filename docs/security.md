# Security model

sapi's job is to let an AI agent run arbitrary commands **against one directory** without being able to touch the rest of your machine. This page says exactly what that does and does not mean.

## What the agent can reach

| | Access |
|---|---|
| The directory you ran `sapi` in (recursively) | read / write |
| `sapi-config` volume (pi credentials, settings, extensions) | read / write |
| Its own sessions volume | read / write |
| The network | yes (it needs model APIs; `git`, `curl`, `npm`, `uv` work) |
| Anything else on your filesystem | **no** |
| Your shell environment, SSH keys, cloud credentials | **no** (nothing is passed in) |
| The Docker socket / other containers | **no** |

If you want the agent to see a repo, `cd` into that repo. If you want it to see your whole home directory, run it there — and understand that you've just granted that.

## Container hardening

`docker create` is called with:

- `--cap-drop ALL` plus only `CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER SETUID SETGID SETPCAP` — exactly what the entrypoint needs to fix volume ownership and drop to your uid. After `setpriv`, the process holds no capabilities.
- `--security-opt no-new-privileges` — no setuid escalation inside the container.
- `--init` — a proper PID 1 so signals and zombies behave.
- No `--privileged`, no `--network host`, no `--pid host`, no socket mounts.

On Linux the agent process runs as **your** uid/gid. On macOS it runs as uid 0 *inside the container*, which Docker Desktop/OrbStack map to your user on the bind mount; it is still root only in the container's namespace.

## What sapi does to your host

- Writes one file: `~/.local/bin/sapi` (or `SAPI_INSTALL_DIR`).
- Creates Docker images (`sapi:*`), containers (`sapi-*`), and volumes (`sapi-config`, `*-sessions`).
- Nothing else. No `sudo`, no profile edits, no launch agents, no telemetry.

## Threat model, honestly

sapi protects against an agent that is **careless or misled** — it runs `rm -rf` in the wrong place, follows a prompt injection in a README, leaks an env var it shouldn't. Those stay inside the box.

sapi does **not** protect against:

- **Docker/kernel escapes.** Containers are a strong boundary but not a VM. If this matters to you, run sapi inside a VM.
- **Harm to the mounted directory itself.** The agent can delete or rewrite everything in it. Use git. Commit before you let it loose.
- **Exfiltration over the network.** The agent has internet. Secrets inside the mounted directory (`.env` files, keys) are readable by it and by whatever model provider you use. Keep secrets out of directories you hand to an agent.
- **A compromised upstream.** sapi installs `pi` from npm and base images from Docker Hub/GHCR at build time, and `pi` self-updates on start. Set `SAPI_AUTO_UPDATE=0` and pin `SAPI_PI_VERSION` if you need reproducibility over freshness.

## Supply chain of sapi itself

- `install.sh` fetches `sapi` over HTTPS from GitHub at a ref you control (`SAPI_REF`). Pin a tag for reproducible installs.
- Both files are short and plain bash. Read them.
- `sapi dockerfile` prints the exact image definition that will be built; nothing hidden.

## Reporting

Open a GitHub issue. If it's sensitive, say so in the title and we'll move to a private channel.
