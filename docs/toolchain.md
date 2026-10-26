# Toolchain customization

The default image contains Debian, Node, pi, git, ripgrep, jq, curl, an SSH client, and `uv`/`uvx`. Python can be provisioned by uv; sapi does not preinstall it. Add other tools through Debian packages or a trusted user Dockerfile fragment.

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
RUN npm install --global --ignore-scripts typescript
ENV PAGER=less
```

If the file exists it is appended verbatim after the packages layer. Another path: `sapi config set dockerfile_extra /path` or `SAPI_DOCKERFILE_EXTRA`.

Do not set `USER`: the entrypoint needs to start as root to repair volume ownership and switch to the configured uid. Install tools and their supporting files in locations accessible to that uid, not only under `/root`. For example, moving rustup's command shims alone does not move its toolchains. Fragments can execute arbitrary build steps; review them before use.

## How caching works

The image tag uses the first 12 hex digits of SHA-256 over the requested pi version string and effective Dockerfile. Changing packages or the fragment changes the tag; an existing tag is reused, a missing image is built. `SAPI_REBUILD=1` forces `--no-cache --pull`. Mutable base/package sources mean this is caching, not a complete dependency lock. Old tagged images remain until explicitly removed with `docker image rm IMAGE`; ordinary `docker image prune` removes dangling images, not all old tagged sapi images.

`sapi dockerfile` always prints the complete effective Dockerfile. There is nothing hidden between what you read and what gets built.

## Why only user-level

Sapi reads the user's selected config/fragment, not an automatic project Dockerfile. Settings apply across workspaces unless overridden for an invocation. A repository cannot silently select build steps, but explicitly pointing `SAPI_CONFIG_FILE` or `SAPI_DOCKERFILE_EXTRA` at an untrusted project file still grants that trust. See [configuration](configuration.md).

If you work on projects with very different needs, keep fragments per project in your config dir and switch with `SAPI_DOCKERFILE_EXTRA="$HOME/.config/sapi/go.df" sapi`.

## Troubleshooting

- **Build fails on a package name** — `apt-cache search NAME` in a Debian bookworm container, or check [packages.debian.org](https://packages.debian.org/bookworm/). sapi validates the *shape* of names, not their existence.
- **Tool installed but "not found" inside the agent** — it was installed into `/root`; on Linux the agent runs as your uid with `HOME=/home/sapi`. Install to `/usr/local/bin` or set `PATH` with `ENV`.
- **Image rebuilt unexpectedly** — something in the effective Dockerfile changed (`sapi dockerfile`), or `SAPI_PI_VERSION` did.
