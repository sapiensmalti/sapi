# Backup, run, diff, restore

The container limits host access; it does not prevent damage inside the mounted workspace. Safer mode takes a backup before an agent start. Diff and restore work without git.

| Task | Command |
|---|---|
| Back up before starting | `sapi --safer` or `sapi --safer run TASK` |
| Back up without starting | `sapi backup` |
| List this workspace's backups | `sapi backups` |
| Compare with the latest backup | `sapi diff` or `sapi diff --full` |
| Restore selected paths in place | `sapi restore latest --files PATH...` |
| Restore the whole tree beside the workspace | `sapi restore latest` |

**Stop agents and other writers before diff or restore.** Detaching with Ctrl-P, Ctrl-Q leaves the agent running. Use `sapi ls` to find it and `docker stop NAME` to stop it.

## Safer mode and backups

```sh
sapi --safer                         # this invocation
sapi config set safer true           # subsequent agent starts, including run
sapi --no-safer run "Explain this project."   # override the saved setting
```

Config and environment values are validated before any agent launch. An explicit `--safer` flag takes precedence over `SAPI_SAFER`; see [configuration](configuration.md#config-file).

A backup contains the whole workspace: `.git`, hidden files, build output, secrets, and symlinks. It is a `tar.gz` with one top-level directory. Filesystem modes and timestamps are stored; this is not a filesystem snapshot or a record of every filesystem attribute.

Backups live outside the workspace, by default under `~/.local/share/sapi/backups/<dirname>-<path-hash>/`. Override the root with `backup_dir` / `SAPI_BACKUP_DIR`. The directory is mode 0700 and archive/metadata files are 0600. Archives are not encrypted or off-site.

```text
20261025T074811Z.tar.gz             archive
20261025T074811Z.tar.gz.sha256      checksum
20261025T074811Z.tar.gz.manifest    source, time, version, size, entries, tar result
20261025T074811Z.tar.gz.run         headless-run summary, when written
```

Before starting the selected agent, sapi checks that the backup location is outside the workspace, acquires a per-workspace lock, checks space, writes the archive, rereads its listing, and calculates its SHA-256. Metadata is written before the archive is renamed into place. Failure aborts the new agent start; it does not stop other agents already running.

GNU tar's exit 1 is accepted with a warning and recorded in the manifest; higher exit codes abort. Concurrent writes may produce a mixed-time or mid-write backup, and tar cannot detect every change. Keep other writers stopped when you need a stable tree.

`backup_keep` defaults to 10 archives per workspace; `0` keeps all. Pruning removes the oldest archives and their metadata. This bounds the number of backups, not their total size. Names are UTC timestamps; same-second collisions wait for the next second.

Known-dead lock owners can be recovered automatically. Missing/malformed ownership or interrupted lock recovery fails closed; see [troubleshooting](troubleshooting.md). Normal errors and caught signals attempt cleanup. Power loss and `SIGKILL` cannot run cleanup, and rename ordering is not a guarantee of power-loss durability.

## Headless tasks

```sh
sapi --safer run --timeout 900 "Run the tests and fix the failures."
printf '%s\n' "Summarise this project." | sapi run -
sapi run --json "Explain the test failures." > events.jsonl
```

- Each task uses a new, automatically removed container. Its session files use a persistent per-workspace volume.
- Default stdout is pi's final message; `--json` selects pi's event stream. Sapi diagnostics go to stderr.
- Normal exit status is the agent/container's result. A timeout returns `124`; caught signals keep their usual statuses.
- `--timeout S` begins after container launch, includes container startup/update time, and does **not** cover the preceding image build, backup, or sidecar setup. Stopping the container can add a grace period. `0` means no timeout.
- Sapi passes pi `--no-approve` to ignore project-local resources for the run. This is not a tool-approval mechanism or protection from prompt injection in files the agent reads.

With safer mode, a normally completed `run` writes a `.run` summary beside its backup, including nonzero exits and timeouts. It contains the task's first 2,000 bytes with newlines flattened, the container, timestamps, exit code, requested model (or `default`), and sapi version. An interrupted run may leave a backup without a run summary. Redirect output to a file outside the workspace if you also need a host-side record of stdout/stderr; it may contain secrets.

These artifacts aid review, but are not a tamper-proof audit log. Session files are writable by the agent, and diff compares the current tree, not a saved after-state attributable to one run. Later edits or concurrent tasks affect the comparison.

## Diff

```sh
sapi diff                            # latest backup for this workspace
sapi diff /path/to/backup.tar.gz --full
```

Output lists `A`dded, `M`odified, and `D`eleted paths. Regular files are compared by content hash and mode; directories by mode; symlinks by target without following them. Other special files are identified by type. Timestamps, ownership, ACLs, and extended attributes are not compared. Control-character paths are escaped for display.

`--full` adds unified hunks for regular files. No git repository is needed, and git-ignored files are included. Comparison exit status: **0 unchanged, 1 changes, 2 error**; caught signals retain their usual statuses. Startup and config validation errors also use `2`, so `1` is reserved for a completed comparison with differences.

Diff verifies an available checksum sidecar; a missing checksum produces a warning. It extracts the backup and hashes both trees, so large workspaces need time and temporary disk space. `$TMPDIR` must be outside the workspace. Restore or diff only archives you trust: a checksum detects corruption, not malicious authorship.

## Restore

```sh
sapi restore latest --files src/main.rs README.md
sapi restore latest                         # new sibling: <workspace>.restored-<UTC stamp>
sapi restore /path/to/backup.tar.gz /some/new-or-empty-directory
```

An explicit archive can replace `latest` in either mode. Restore verifies an available checksum and checks for one top-level directory with no absolute or parent-traversing member names. Missing checksums are reported as unverified.

**Whole-tree restore** stages the extracted tree beside a new or empty destination, then moves it into place. The default destination is a sibling of the workspace; a nonempty destination is refused.

**Selected restore** writes into the workspace. Paths must be relative, present in the backup, and contain no `..` component. Quote filenames containing spaces or shell metacharacters. Destination symlink parents are refused; selecting a symlink replaces the link, not its target. **Selecting a directory replaces the directory exactly**, removing additions made since the backup. It is not a merge.

Each selected item is staged beside its destination before replacement. Selections are processed in order, not as one transaction: earlier successful selections remain restored if a later one fails. On a failed swap or caught signal, sapi attempts rollback. If it cannot safely restore the original, it preserves it at `.sapi-restore.*/old` and prints that path. Recover it before deleting the staging directory or retrying.

Standard tar tools remain available for inspection or recovery: `tar -tzf FILE` lists an archive.

## Sessions and shells

`sapi shell [NAME]` opens Bash in `/pi-sessions` and requires an interactive terminal. Its behavior depends on whether an agent is running:

| Situation | Shell behavior |
|---|---|
| Running agent for this workspace | Join it; inherit its network, mounts, and passed environment. |
| No selected running agent | Create a temporary shell with the config and selected session volumes; no network by default. |
| Temporary shell with `--net` | Use Docker's default network, not the configured agent allowlist. |

`--net` does not change a running agent's network. Shells always expose the mounted workspace and config volume; they are not read-only viewers. If several agents are running, use `sapi shell NAME` to choose one.

| Path | Data |
|---|---|
| `/workspace` | Current project |
| `/pi-config` | Shared pi credentials, settings, extensions, and gitconfig |
| `/pi-sessions` | Selected agent slot's session files (`NAME-sessions` volume) |
| `/pi-sessions-runs` | Headless-run session files, mounted in a temporary shell if that workspace's run volume exists |

A shell joining a running interactive agent does not add the headless-run volume. Session records are pi's JSONL format, not the same as `run --json` events. Inside a shell, `ls -lt /pi-sessions` locates them; for a chosen file, `jq -c 'select(.type == "message") | .message.role' FILE.jsonl` lists recorded message roles.

`sapi rm` stops/removes this workspace's containers and deletes its session volumes, including headless-run history. `--all` applies to all managed projects. Config volumes, workspace files, backups, and images remain. See [configuration](configuration.md) for custom config volumes and resource limits.
