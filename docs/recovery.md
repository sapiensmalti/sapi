# Recovery: backup → run → diff → restore

The sandbox stops the agent from touching anything *outside* the directory you run `sapi` in. It does nothing about what happens *inside* it. This page is about the inside: how to always be able to see what the agent did and to take it back — interactively, or unattended from a cron job.

Four commands, one loop:

| | Command | What you get |
|---|---|---|
| **before** | `sapi --safer` / `sapi config set safer true` | a complete, checksummed backup, taken immediately before the agent gets access |
| **during** | `sapi run TASK` | one headless task; final message on stdout; the agent's exit code |
| **after** | `sapi diff` | every path added, modified or deleted since the backup; `--full` for the hunks |
| **undo** | `sapi restore latest --files PATH…` / `sapi restore latest` | put back selected files in place, or the whole tree beside the original |

## Safer mode

Three ways to enable it, in order of precedence (higher wins):

```sh
sapi --safer                 # this run only  (--no-safer forces it off)
SAPI_SAFER=1 sapi            # this shell
sapi config set safer true   # always, for this user
```

`sapi config show` prints every effective setting and where it came from.

### What a backup is

A `tar.gz` of the whole directory, taken from its parent, so the archive contains `<dirname>/…`. Symlinks are stored as symlinks. Modes and timestamps are preserved. Nothing is excluded — not `.git`, not `node_modules`, not `.env`. A backup that leaves things out is not a backup.

It is stored **outside** the directory, where the agent cannot reach it:

```
~/.local/share/sapi/backups/<dirname>-<hash>/
    20261025T074811Z.tar.gz            the archive            (mode 0600)
    20261025T074811Z.tar.gz.sha256     checksum, sha256sum -c format
    20261025T074811Z.tar.gz.manifest   source, time, size, entry count, sha256, tar exit code, duration
    20261025T074811Z.tar.gz.run        (after `sapi run`) task, container, start/finish, exit code, model
```

`<hash>` is derived from the absolute path, so two directories with the same name never share a folder. Names are UTC timestamps and sort chronologically; a same-second collision waits for the next second rather than adding a suffix. Change the root with `SAPI_BACKUP_DIR` or `backup_dir`.

### How it is made

1. **Preconditions**: `tar` exists; the directory is not `/`; the backup root is not inside the directory (checked textually *and* after resolving symlinks); its permissions are enforced to 0700; directory measurement and the free-space check must succeed. A portable `mkdir` lock refuses a concurrent backup for the same project and recovers stale locks.
2. `tar -czf` into a private transaction directory. GNU tar's exit 1 ("file changed as we read it") is recorded as a warning in the manifest; anything worse aborts.
3. The archive is re-read in full (`tar -tzf`) to prove it is readable and non-empty.
4. SHA-256 and metadata are completely written, then the archive is renamed into place as the commit point. A crash can leave harmless orphan sidecars, cleaned by a later backup, never an apparently complete archive with half-written metadata.
5. Backups beyond `backup_keep` (default 10; `0` = keep all) are pruned with their checksum/manifest/run sidecars, oldest first.

On an ordinary error or signal, **the launch is aborted** and transaction/lock state is cleaned. (A power loss or `SIGKILL` cannot run cleanup; the next backup recovers it.) The container is created only after step 5, so what the agent sees is exactly what was archived.

## `sapi run`: headless

```sh
sapi run "Update CHANGELOG.md from the git log since the last tag."
sapi run --timeout 900 "Fix every failing test in packages/api."
echo "Summarise this repository in 10 lines." | sapi run -
sapi run --json "…" > events.jsonl          # pi's full event stream instead of the final message
```

- One ephemeral container (`--rm`), the same mounts, hardening and resource ceilings as interactive mode.
- Final assistant message on **stdout**; sapi's own progress on **stderr**; exit code = the agent's exit code (`124` on `--timeout`).
- Project-local pi files (`.pi/`) are **not** trusted (`--no-approve`): an unattended run must not pick up extensions from the tree it is editing.
- No TTY required. It composes with everything: pipes, `xargs -P`, Makefiles, CI, cron.

### Resource ceilings

Both modes honour `cpus`, `memory_mib` and `pids` (`SAPI_CPUS`, `SAPI_MEMORY_MIB`, `SAPI_PIDS`, or the config file). Defaults: unlimited, unlimited, 4096 processes. A confused agent running a fork bomb or an unbounded build should not take the host down with it.

## `sapi diff`: what changed

```
$ sapi diff
M  src/auth/session.ts
A  src/auth/session.test.ts
D  src/auth/legacy.ts
sapi: diff: 1 added, 1 modified, 1 deleted · vs 20261025T074811Z.tar.gz · run exit 0
```

Compares the directory **now** against the latest backup (or a given one: `sapi diff FILE`). If a checksum sidecar exists it must match; a missing one produces an explicit unverified-integrity warning. `--full` appends unified hunks for regular files (`--- backup/…`, `+++ now/…`). Exit status follows `diff(1)`: `0` no changes, `1` changes, `>1` trouble — so `sapi diff || notify` works.

The comparison uses private manifests of content hashes, file types, permission modes, and symlink targets. A chmod, type change, or same-content symlink retarget is therefore a modification. It never recursively follows symlinks, and unusual/control-character paths are escaped rather than interpreted.

It needs no git. It works when the project is not a repository, when `.git` itself was deleted, and for files git would ignore.

## `sapi restore`: take it back

```sh
sapi restore latest --files src/auth/legacy.ts src/auth/session.ts   # just these, in place
sapi restore latest                                                 # whole tree → ../<dirname>.restored-<stamp>/
sapi restore FILE /some/empty/dir                                   # whole tree → there
```

- Restore verifies an available checksum and refuses a corrupt archive; missing/invalid metadata is never presented as verified. Archives must have one top-level directory and no absolute/parent-traversing members. **Restore only archives you trust: a checksum proves integrity, not authorship.**
- **Whole-tree restore never writes into the original directory.** It stages a complete tree beside a new or empty destination and moves it into place; failure does not leave a half-extracted destination.
- **`--files` is the only in-place operation**, and it touches exactly the paths you name — relative, inside the directory, present in the backup; parent traversal and absolute paths are refused, while a name such as `a..b` is valid.
- Each selected path is staged beside its destination and swapped in without following destination symlinks. **Selecting a directory replaces that directory exactly**: files created beneath it since the backup are removed. Unrelated paths are untouched.
- Everything is standard tar: you can inspect an archive with `tar -tzf FILE` without sapi.

## Unattended: auditable and reversible by construction

Put safer mode and `run` together and every automated task leaves a complete, independent record:

```sh
# crontab: nightly, 15-minute budget, logs kept with the backups
0 2 * * *  mkdir -p "$HOME/.local/share/sapi" && cd "$HOME/code/service" && \
             SAPI_SAFER=1 "$HOME/.local/bin/sapi" run --timeout 900 \
             "Review yesterday's commits for security issues; fix trivial ones; summarise the rest in REVIEW.md" \
             >> "$HOME/.local/share/sapi/service-cron.log" 2>&1
```

What exists the next morning, for that one run, all outside the agent's reach:

| Artifact | Answers |
|---|---|
| `<stamp>.tar.gz` + `.sha256` + `.manifest` | *What did the tree look like before?* — complete, verified, restorable |
| `<stamp>.tar.gz.run` | *What was it asked, when, how long, which model, how did it exit?* |
| `service-cron.log` (stdout + stderr) | *What did it say?* — its final message, plus sapi's own lines |
| `sapi diff <stamp>.tar.gz` | *What did it actually change?* — every path, with hunks on request |
| `sapi restore <stamp>.tar.gz --files …` | *Undo exactly that* — one file or the whole tree, without touching anything else |
| `sapi shell` → `/pi-sessions-runs/*.jsonl` | *Every message, tool call and result of the run* — pi's own session file, in a shell with no network |

Each night's run gets its own backup, so the chain of backups is a chain of before-states; `backup_keep` bounds how far back it reaches. This is auditability (every input and output of the run is recorded, independently of the agent and independently of git) and reversibility (any subset of its effects can be undone, verified against a checksum) — with zero cooperation required from the agent, the model, or the repository.

A review workflow that fits in one line:

```sh
sapi diff >/dev/null || { sapi diff --full | less; }     # anything changed? show me
```

## Config file

`~/.config/sapi/config` (or `$XDG_CONFIG_HOME/sapi/config`; override with `SAPI_CONFIG_FILE`):

```
# sapi settings
safer = true
backup_dir = /Volumes/External/sapi-backups
backup_keep = 10
cpus = 4
memory_mib = 8192
pids = 4096
```

Rules: `key = value`, full-line `#` comments, lower-case keys (`sapi config keys` lists them with their types), booleans as `true/false/yes/no/on/off/1/0`, paths absolute, counts non-negative integers. `#` elsewhere is literal, so paths such as `/tmp/a#b` round-trip unchanged. The file is parsed, never sourced. An unknown key or invalid value makes sapi refuse to start — a safety setting silently ignored because of a typo would be worse than no setting at all. `sapi config set` writes the file atomically with mode 0600 and preserves other lines.

## Costs and limits

- **Time and disk.** A backup of a directory with a large `node_modules` or build output takes as long as tarring it. Each run adds one archive; pruning bounds the count, not the size. Put `backup_dir` on a volume with room.
- **Point in time, not crash-consistent.** Files written by other programs during the second or two of archiving may be captured mid-write. sapi reports this (`tar_exit = 1` in the manifest).
- **Secrets travel with it.** The archive contains whatever the directory contains. It is `0600` in a `0700` folder; it is not encrypted.
- **Not off-site.** The backup lives on the same machine. It protects against the agent, not against the disk.
- **`diff` extracts and hashes the backup and current tree** in private temporary storage; for very large trees that costs I/O and `$TMPDIR` space. Selective restore also stages the archive before swapping selected paths. `TMPDIR` must be outside the workspace.

## `sapi shell`: where pi keeps its files

```
$ sapi shell
  /pi-config          pi settings, auth.json, extensions, gitconfig  (volume sapi-config)
  /pi-sessions        session files (*.jsonl) of the interactive agent  (volume sapi-<dir>-<hash>-sessions)
  /pi-sessions-runs   session files of `sapi run`  (volume sapi-<dir>-<hash>-runs-sessions)
  /workspace          /home/you/code/project
sapi@sapi:/pi-sessions$ ls -t | head
```

One command, no prerequisites. If an agent for this directory is running you are placed inside it; otherwise an ephemeral container with the same hardening and the same volumes is started — and removed when you leave. Ephemeral shells have **no network** unless you pass `--net`: a shell with the credentials volume mounted should not have egress by accident. On Linux the shell runs as your uid, like the agent, so anything you create is yours. `sapi shell NAME` targets a specific container's sessions.

Session files are pi's own record of every message, tool call and result — the finest-grained audit trail there is. `jq -c 'select(.type == "message_end") | .message.role' *.jsonl` is a good first look; see pi's [session format](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/session-format.md).
