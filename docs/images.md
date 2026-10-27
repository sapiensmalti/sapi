# Agent images and builds

Normal starts use a tested multi-architecture image pinned by digest. Docker chooses the matching amd64/arm64 image, downloads it once, and reuses it locally. The published starting version is pi 1.4.0.

**Automatic pi updates remain enabled by default.** The digest pins the starting image, not the running installation after an update. `SAPI_AUTO_UPDATE=0` disables the startup update attempt. An allowlist without `@npm` also skips it. No source-build or customization option implicitly disables updates.

## Image selection

| Invocation/settings | Preparation if not cached |
|---|---|
| Default | Pull the exact published digest; no local npm/apt build |
| `packages` or `Dockerfile.extra` | Build a layer on the pinned image |
| `SAPI_BUILD=1` | Build the full embedded recipe using the reviewed starting pi version |
| A different `SAPI_PI_VERSION`, including `latest` | Build the full recipe with that requested pi version |
| `SAPI_REBUILD=1` | Force the full recipe with `--no-cache --pull` |
| `SAPI_IMAGE=NAME` | Use an existing image as supplied; otherwise build the selected recipe under that tag |

An explicit pi version equal to the published starting version can use the published base. An existing customized image is reused without re-downloading its base. `SAPI_BUILD=1` selects a recipe, not a forced rebuild; use `SAPI_REBUILD=1` to discard build cache. A custom digest reference must be pulled explicitly before use; it cannot be an output build tag.

All managed agents and shells remain root (`0:0`) in every mode. Workspaces are not build contexts; local builds use an empty private temporary context. The Docker socket is never mounted into the agent.

## Commands

```sh
sapi build                          # prepare the default/custom image; do not start
sapi dockerfile                     # selected recipe, including custom layers
SAPI_BUILD=1 sapi dockerfile         # inspect the full embedded source recipe
SAPI_BUILD=1 sapi                    # explicitly build from source if needed
SAPI_PI_VERSION=latest sapi          # build a starting pi from npm's latest tag
SAPI_REBUILD=1 sapi build            # force a clean full-source rebuild
```

Docker 23+ is required. **Buildx is needed only when a local build is necessary**, including custom tools or source-built sidecars. Cached/default image use does not require it. On Debian, Docker's official packages include the `docker-buildx-plugin` package.

`sapi dockerfile` prints a build recipe, not a reconstruction of a cached custom image. An existing `SAPI_IMAGE` is an explicit trust decision and may have entirely different contents; it must provide the compatible root entrypoint. A custom fragment may alter software after the base is selected. See [toolchains](toolchain.md) and [security](security.md).

## Failure behavior

If a pull fails, sapi stops with an error. It does not silently substitute a tag, an older image, or a fresh mutable npm build. Retry the pull, or explicitly select `SAPI_BUILD=1` if you want the source-build path; that path also needs its upstream build inputs.

After locating the canonical image, sapi verifies its declared root identity, baked pi-version label, and build-definition fingerprint against the embedded source recipe. A mismatch stops preparation. Use a matching sapi version or explicitly build source; do not suppress the check.

Pull/build progress goes to stderr, so `sapi run` stdout remains the agent's final message or JSON event stream. Image preparation still happens before `run --timeout` begins. Backups happen after preparation and before the selected agent starts.

## Releases and transparency

The [agent-image workflow](../.github/workflows/agent-image.yml) builds amd64 and arm64 candidates natively. It checks the actual pi version and root identity, runs the kernel smoke suite against each exact candidate, and verifies the candidate image ID did not change before publishing. Only successful architectures enter the multi-architecture manifest.

Release assets include the tagged source archive, its SHA-256, and `PINS`: image digest, starting pi version, build-definition fingerprint, and source checksum. OCI labels record the source repository, revision, version, and starting pi version. The launcher contains the image digest and the complete source recipe; no host package manager or daemon is added by sapi.

A published image is a tested snapshot, **not proof that rebuilding the source yields identical bytes**. Source/derived builds still depend on mutable package repositories and base tags. Automatic updates, manual package installations, and agent writes can change a running container independently of the original image. Containers remain disposable; volumes and workspace files have their separate lifetimes.
