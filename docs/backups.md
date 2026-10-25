# Safer mode: backups

The sandbox stops the agent from touching anything *outside* the directory you run `sapi` in. It does nothing about what happens *inside* it. Safer mode closes that gap: before every start, sapi takes a complete backup of the directory, and refuses to start if it cannot.

## Turn it on

Three ways, in order of precedence (higher wins):

```sh
sapi --safer                 # this run only  (--no-safer forces it off)
SAPI_SAFER=1 sapi            # this shell
sapi config set safer true   # always, for this user
```

`sapi config show` prints the effective settings and where each came from.

## What a backup is

A `tar.gz` of the whole directory, taken from its parent, so the archive contains `<dirname>/…`. Symlinks are stored as symlinks. File modes and timestamps are preserved. Nothing is excluded — not `.git`, not `node_modules`, not `.env`. A backup that leaves things out is not a backup.

It is stored **outside** the directory, where the agent cannot reach it:

```
~/.local/share/sapi/backups/<dirname>-<hash>/
    20261025T074811Z.tar.gz            the archive            (mode 0600)
    20261025T074811Z.tar.gz.sha256     checksum, sha256sum -c format
    20261025T074811Z.tar.gz.manifest   source, time, size, entry count, sha256, tar exit code, duration
```

`<hash>` is derived from the absolute path, so two directories with the same name never share a folder. Names are UTC timestamps, so they sort chronologically. Change the root with `SAPI_BACKUP_DIR` or `backup_dir`.

## How it is made

1. Preconditions: `tar` exists; the directory is not `/`; the backup root is not inside the directory (checked textually *and* after resolving symlinks, before anything is created); free space at the destination exceeds the directory's size plus a margin.
2. `tar -czf` into a hidden `.partial` file. GNU tar's exit 1 ("file changed as we read it") is recorded as a warning; anything worse aborts.
3. The archive is re-read in full (`tar -tzf`) to prove it is readable and non-empty.
4. SHA-256 is computed; the file is renamed into place; the sidecar and manifest are written.
5. Backups beyond `backup_keep` (default 10; `0` = keep all) are pruned, oldest first — only files sapi created, only in that directory's folder.

If any step fails, the launch is aborted with the reason, and no partial file is left behind. The container is created only after step 5, so what the agent sees is exactly what was archived.

## Restore

```sh
sapi backups                            # list this directory's backups
sapi restore <file>                     # → ../<dirname>.restored-<stamp>/
sapi restore <file> /some/empty/dir     # → there
```

Restore verifies the checksum first and refuses a corrupt archive. It extracts into a **new or empty** directory, never over the original: compare with `diff -r`, then decide what to move. Everything is standard tar; without sapi, `tar -xzf <file>` does the same.

## Config file

`~/.config/sapi/config` (or `$XDG_CONFIG_HOME/sapi/config`; override with `SAPI_CONFIG_FILE`):

```
# sapi settings
safer = true
backup_dir = /Volumes/External/sapi-backups
backup_keep = 10
```

Rules: `key = value`, `#` comments, lower-case keys from the list above, booleans as `true/false/yes/no/on/off/1/0`, paths absolute, counts non-negative integers. The file is parsed, never sourced. An unknown key or invalid value makes sapi refuse to start — a safety setting silently ignored because of a typo would be worse than no setting at all. `sapi config set` writes the file atomically with mode 0600 and preserves other lines.

## Costs and limits

- **Time and disk.** A backup of a directory with a large `node_modules` or build output takes as long as tarring it. Each run adds one archive; pruning bounds the count, not the size. Put `backup_dir` on a volume with room.
- **Point in time, not crash-consistent.** Files written by other programs during the second or two of archiving may be captured mid-write. sapi reports this (`tar_exit = 1` in the manifest).
- **Secrets travel with it.** The archive contains whatever the directory contains. It is `0600` in a `0700` folder; it is not encrypted.
- **Not off-site.** The backup lives on the same machine. It protects against the agent, not against the disk.
