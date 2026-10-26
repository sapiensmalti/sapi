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

The agent is always launched as root. Sapi appends `USER 0:0` after fragments and enforces it again at runtime; a fragment cannot select a different agent user. Tools under `/root` are available to the root agent, but container-local installations disappear when the container is replaced. For persistent tool availability, bake the full installation into the image. Fragments can execute arbitrary build steps; review them before use.

## How caching works

The image tag uses the first 12 hex digits of SHA-256 over the requested pi version string and effective Dockerfile. Changing packages or the fragment changes the tag; an existing tag is reused, a missing image is built. `SAPI_REBUILD=1` forces `--no-cache --pull`. Mutable base/package sources mean this is caching, not a complete dependency lock. Old tagged images remain until explicitly removed with `docker image rm IMAGE`; ordinary `docker image prune` removes dangling images, not all old tagged sapi images.

`sapi dockerfile` always prints the complete effective Dockerfile. There is nothing hidden between what you read and what gets built.

## Why only user-level

Sapi reads the user's selected config/fragment, not an automatic project Dockerfile. Settings apply across workspaces unless overridden for an invocation. A repository cannot silently select build steps, but explicitly pointing `SAPI_CONFIG_FILE` or `SAPI_DOCKERFILE_EXTRA` at an untrusted project file still grants that trust. See [configuration](configuration.md).

If you work on projects with very different needs, keep fragments per project in your config dir and switch with `SAPI_DOCKERFILE_EXTRA="$HOME/.config/sapi/go.df" sapi`.

## Troubleshooting

- **Build fails on a package name** — `apt-cache search NAME` in a Debian bookworm container, or check [packages.debian.org](https://packages.debian.org/bookworm/). sapi validates the *shape* of names, not their existence.
- **Tool installed but "not found" inside the agent** — check `PATH` and whether the tool was installed only in a previous container's writable layer. Root uses `HOME=/root`; bake persistent tools into the image.
- **Image rebuilt unexpectedly** — something in the effective Dockerfile changed (`sapi dockerfile`), or `SAPI_PI_VERSION` did.
