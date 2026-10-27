# Configuration

`sapi config` shows effective config-file settings and where each value came from. `sapi config keys` lists the accepted keys. Model selection, version controls, and other environment-only options are listed separately below.

## Config file

Default: `~/.config/sapi/config`. `$XDG_CONFIG_HOME/sapi/config` or `SAPI_CONFIG_FILE` can change it; `sapi config path` prints the selected path.

```sh
sapi config set safer true
sapi config set memory_mib 8192
sapi config set packages "golang make"
```

The corresponding file contains unquoted values:

```text
# sapi settings
safer = true
memory_mib = 8192
packages = golang make
```

Precedence: **flag > environment > config file > default**. Only `safer` has command-line flags (`--safer` / `--no-safer`, before the command). A set-but-empty environment variable overrides config: it clears `packages` or `allow`, but is invalid for scalar settings.

Every effective value is validated before an image build, volume creation, or agent launch. Invalid environment overrides abort rather than clearing a safety setting. Empty `packages` and `allow` lists are honored in both the config file and environment.

The file is parsed, never executed. Use one `key = value` per line. Blank lines and whole-line `#` comments are allowed; elsewhere `#` is literal. Shell quoting, variable expansion, and `~` expansion are not performed in the file. Paths must be absolute. Unknown keys or invalid values cause an error. `sapi config set` validates the value and replaces the file atomically with mode 0600.

## Persistent settings

Defaults below assume no XDG or config-path override.

| Config key | Environment override | Default / meaning |
|---|---|---|
| `safer` | `SAPI_SAFER` | `false`; backup before interactive/headless agent starts |
| `backup_dir` | `SAPI_BACKUP_DIR` | `~/.local/share/sapi/backups`; must be outside the workspace |
| `backup_keep` | `SAPI_BACKUP_KEEP` | `10` per workspace; `0` keeps all |
| `cpus` | `SAPI_CPUS` | `0` = unlimited; accepts a non-negative decimal |
| `memory_mib` | `SAPI_MEMORY_MIB` | `0` = unlimited; integer MiB |
| `pids` | `SAPI_PIDS` | `4096`; `0` = unlimited |
| `packages` | `SAPI_PACKAGES` | Empty; comma/space-separated Debian package names |
| `dockerfile_extra` | `SAPI_DOCKERFILE_EXTRA` | `Dockerfile.extra` beside the selected config file; appended if present |
| `network` | `SAPI_NETWORK` | `full`; or `allowlist` |
| `allow` | `SAPI_ALLOW` | `@providers`; used only in allowlist mode |

Booleans accept `true/false`, `yes/no`, `on/off`, or `1/0`, case-insensitively. Counts are non-negative integers. The backup root also honors `XDG_DATA_HOME`.

- [Recovery](recovery.md): backups, timeouts, diff, and restore.
- [Toolchains](toolchain.md): image packages and Dockerfile fragments.
- [Network](network.md): allowlist syntax and presets.

## Environment-only controls

These are **not** accepted by `sapi config set`.

| Variable | Default / meaning |
|---|---|
| `SAPI_MODEL` | Unset: pi selects the model. Otherwise passed to `pi --model`. |
| `SAPI_PI_VERSION` | Published starting version (`1.4.0`); a different version or `latest` selects a full-source build. Startup updates are separate. |
| `SAPI_AUTO_UPDATE` | `1`, unchanged for published images; `0` disables pi's update attempt on agent start |
| `SAPI_BUILD` | `0`; `1` selects the full embedded source recipe instead of the published base |
| `SAPI_REBUILD` | `0`; `1` forces a full-source build with `--no-cache --pull` |
| `SAPI_UID` / `SAPI_GID` | Legacy compatibility controls: agent commands accept only `0`; all agents/shells start as `0:0` |
| `SAPI_CONFIG_VOLUME` | `sapi-config`; shared pi credentials/settings volume |
| `SAPI_ENV` | Empty; whitespace-separated names of host variables to pass through |
| `SAPI_DOCKER_ARGS` | Empty; extra Docker arguments, whitespace-split without quote interpretation or glob expansion |
| `SAPI_IMAGE` | Use an existing image as supplied, or build the selected recipe under this name/tag if missing; custom digest references must be pre-pulled |
| `SAPI_EGRESS_IMAGE` | Override the digest-pinned sidecar image |
| `SAPI_EGRESS_BUILD` | `1` builds the sidecar from checksum-pinned source instead of pulling it |

Root identity is fixed inside the container, regardless of the host user or OS. Remove old nonzero `SAPI_UID` / `SAPI_GID` settings; zero-padded zero values are normalized. Extra `--user`, `--cgroupns`, or `--entrypoint` Docker flags cannot override the managed launch policy. Custom images must provide the compatible `/usr/local/bin/sapi-entrypoint`; arbitrary custom image/build code remains a trust decision.

On Linux, agent-created workspace files may be root-owned, and private root-owned files can make host-side backups fail. Sapi does not automatically chown the workspace. See [agent identity](security.md#agent-identity).

`SAPI_ENV` passes names, not literal assignments: after exporting a provider key, use `SAPI_ENV=OPENROUTER_API_KEY sapi`. Containers using `SAPI_ENV` are recreated on start so secret values do not become stale; those values are not hashed into labels.

For a separate credential/settings trust domain:

```sh
SAPI_CONFIG_VOLUME=sapi-config-review sapi
```

Use the same variable on later starts and shells to access that volume. This does not make an untrusted project safe by itself. The workspace, config volume, and session volumes remain writable by the agent.

`SAPI_DOCKER_ARGS`, custom images, and Dockerfile fragments are trusted-user escape hatches that can defeat isolation. Never inherit them from an untrusted project or shell setup. See [security](security.md).

## Versions and installation

The installer defaults to the release tag specified in `install.sh`; it does not query GitHub for the latest release. `sapi upgrade` normally fetches the installer from `main`, which selects the release to install. The install directory defaults to `~/.local/bin` (`SAPI_INSTALL_DIR` overrides it); upgrades replace the running launcher's file in its existing directory.

`SAPI_REF` selects a tag, commit, or branch for installation/upgrade. It is an invocation-time setting, not a saved preference. To install development code:

```sh
curl -fsSL https://raw.githubusercontent.com/sapiensmalti/sapi/main/install.sh | SAPI_REF=main bash
SAPI_REF=main sapi upgrade             # keep following main on a later upgrade
```

An ordinary `sapi upgrade` returns to the installer's selected release. The launcher version string alone may not distinguish unreleased `main` changes from the last tag.

Sapi upgrades do not directly update pi. Pinning `SAPI_PI_VERSION` pins the requested pi version, not its complete transitive dependency graph. Disable automatic pi updates as well when you want to retain the installed version:

```sh
SAPI_PI_VERSION=1.4.0 SAPI_AUTO_UPDATE=0 sapi
```

The default image digest fixes the starting bytes, but automatic updates remain enabled and can change the running installation. Source/customized builds depend on additional mutable inputs. See [images and builds](images.md) and [supply-chain limits](security.md#threat-model); do not confuse a pinned starting image with a frozen running agent.
