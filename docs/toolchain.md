# Toolchain customization

The image ships what an agent needs most of the time: Debian, Node, `pi`, git, ripgrep, jq, curl, ssh, and `uv` for Python. Real projects need more — Go, Rust, `make`, `gcc`, a database client. Two user-level knobs add them without forking sapi.

## Packages

```sh
sapi config set packages "golang make postgresql-client"     # or: SAPI_PACKAGES="golang make"
sapi dockerfile | tail -5                                      # see exactly what will be built
sapi                                                           # builds once; cached by content
```

Names are validated as Debian package names (`[a-z0-9][a-z0-9+.-]+`), comma or space separated. They are installed in one `apt-get install --no-install-recommends` layer appended to the embedded Dockerfile.

## Dockerfile fragment

For anything apt cannot express — a toolchain installer, a global npm package, environment variables:

```dockerfile
# ~/.config/sapi/Dockerfile.extra
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && mv /root/.cargo/bin/* /usr/local/bin/
RUN npm install -g typescript
ENV GOFLAGS=-mod=vendor
```

If the file exists it is appended verbatim after the packages layer. Another path: `sapi config set dockerfile_extra /path` or `SAPI_DOCKERFILE_EXTRA`.

Two rules for fragments: **do not set `USER`** — the entrypoint starts as root and drops to your uid itself; and install tools system-wide (`/usr/local`), not into `/root`, because on Linux the agent runs as you, not root.

## How caching works

The image tag is `sapi:<sha256(pi version + effective Dockerfile)>`. Changing `packages` or the fragment changes the tag, so the next start builds a new image and an unchanged definition is never rebuilt. `SAPI_REBUILD=1` forces `--no-cache --pull` (fresh base image and package versions). Old images stay until you remove them (`docker image prune`).

`sapi dockerfile` always prints the complete effective Dockerfile. There is nothing hidden between what you read and what gets built.

## Why only user-level

Both knobs live in *your* config (`~/.config/sapi/`), never in the project. A `Dockerfile.extra` in a repository you cloned would be code execution on your Docker host at build time, chosen by whoever wrote the repo. sapi ignores project files for this purpose by design; if a project needs a toolchain, you decide to add it, once, and it applies to every directory you run sapi in.

If you work on projects with very different needs, keep fragments per project in your config dir and switch with `SAPI_DOCKERFILE_EXTRA=~/.config/sapi/go.df sapi`.

## Troubleshooting

- **Build fails on a package name** — `apt-cache search NAME` in a Debian bookworm container, or check [packages.debian.org](https://packages.debian.org/bookworm/). sapi validates the *shape* of names, not their existence.
- **Tool installed but "not found" inside the agent** — it was installed into `/root`; on Linux the agent runs as your uid with `HOME=/home/sapi`. Install to `/usr/local/bin` or set `PATH` with `ENV`.
- **Image rebuilt unexpectedly** — something in the effective Dockerfile changed (`sapi dockerfile`), or `SAPI_PI_VERSION` did.
