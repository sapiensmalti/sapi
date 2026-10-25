# Architecture

`sapi` is deliberately small. This page explains the few decisions that matter.

## Pieces

| Piece | Where | Role |
|---|---|---|
| `install.sh` | repo root, fetched by `curl` | Downloads `sapi` to `~/.local/bin`. Nothing else. |
| `sapi` | `~/.local/bin/sapi` | Launcher. Builds the image, manages containers and volumes, attaches your terminal. |
| Dockerfile | embedded in `sapi` (`sapi dockerfile`) | `node:24-bookworm-slim` + git, ripgrep, jq, curl, ssh client + `pi` (npm) + `uv`. |
| `sapi-entrypoint` | embedded in the Dockerfile, `/usr/local/bin/` in the image | Runs on every container start: optional `pi update`, then drops to your uid/gid and execs `pi`. |

Everything is embedded in a single file so that *installing* means *copying one file*, and *reading the whole system* means *reading one file*.

## Image identity

The image tag is `sapi:<sha256(PI_VERSION + Dockerfile)[0:12]>`. Any change to the embedded Dockerfile or to `SAPI_PI_VERSION` yields a new tag and therefore a fresh build; unchanged definitions are never rebuilt. `SAPI_REBUILD=1` forces `--no-cache --pull`.

## Container lifecycle

Container name: `sapi-<dirname>-<sha256(abs path)[0:8]>`, or the name you pass.

On `sapi`:

1. Build the image if its tag is missing.
2. Ensure the global config volume (`sapi-config`) exists.
3. Walk slots `name`, `name-2`, `name-3`, …
   - **No container** → create it here.
   - **Not ours** (missing `sh.sapi.managed` label or different workspace hash) → next slot.
   - **Running** → next slot (you get a second, independent agent).
   - **Stopped, and image/version/model/user/auto-update all match** → `docker start --attach`. Resume.
   - **Stopped, something changed** → remove and recreate in this slot. The sessions volume is reused, so history survives.
4. `docker create` with the labels, mounts and hardening flags, then attach.

Containers are cattle. Volumes are the only state:

- `sapi-config` → `/pi-config` (`PI_CODING_AGENT_DIR`): auth, settings, extensions. Shared by every project.
- `<container>-sessions` → `/pi-sessions` (`PI_CODING_AGENT_SESSION_DIR`): one per container slot.

`sapi rm` removes containers and their session volumes but never the config volume.

## Entrypoint

```
pi update self --no-approve   (unless SAPI_AUTO_UPDATE=0; failure is non-fatal)
if SAPI_UID != 0:
    chown -R uid:gid /pi-config /pi-sessions /home/sapi   (only if ownership differs)
    exec setpriv --reuid uid --regid gid --clear-groups env HOME=/home/sapi pi "$@"
exec pi "$@"
```

The update runs as root because npm's global prefix is root-owned; then privileges are dropped for good. On macOS the default is uid 0 because Docker Desktop and OrbStack translate ownership on bind mounts themselves; on Linux the bind mount is the real filesystem, so matching your uid is what keeps `git status` clean and `rm` working afterwards.

## Safer mode, run, diff

Settings are table-driven (`setting_spec`): one line per key gives type, environment variable and default; parsing, precedence (flag > environment > config file > default) and `sapi config` all read that table. The config file is whitelist-parsed, never sourced.

`container_args` is the single source of the container specification — mounts, environment, hardening, resource ceilings — used by both the interactive start and `sapi run`. When safer mode is on, `backup_create` runs after the image build and before any container exists; `sapi run` additionally writes a run manifest beside the backup. `sapi diff` extracts the backup to a private temp dir and uses portable `diff -rq`. Guarantees and the unattended workflow are in [recovery.md](recovery.md).

## Network egress allowlist

Opt-in. `prepare_network` computes a signature of the expanded allowlist (part of the container's compatibility labels) and whether pi's self-update can run. `egress_start` pulls the digest-pinned sidecar image (or builds it from the pinned source tarball with `SAPI_EGRESS_BUILD=1`), starts it with `NET_ADMIN SETUID SETGID SETPCAP` only, and `egress_wait` blocks on its ready marker before the agent container is created with `--network container:<sidecar>`. The sidecar itself is [`egress/`](../egress): fake DNS, TLS-SNI and HTTP-Host filters, connect-by-name relay, iptables rule table — all pure functions with tests, plus one privileged setup step. Design and guarantees: [network.md](network.md).

## Why bash, not Rust

Docker is doing the heavy lifting: isolation, image caching, lifecycle. The launcher is glue. Glue in bash is auditable in one sitting by anyone, has zero build step, zero dependencies, and ships as a text file. A Rust binary would need per-platform builds, signing on macOS, and a release pipeline — cost with no benefit at this size. If sapi ever grows a long-running component (a daemon, a swarm coordinator, an API), that is where Rust belongs.

## Why `curl | bash`

Because it is the deployment interface people actually use, and because the script is short enough to read first. `install.sh` pins the ref it fetches from (`SAPI_REF`, default `main`), validates the shebang and syntax of what it downloaded, and never escalates privileges. A two-step "download, read, run" is documented for anyone who prefers it.
