# Changelog

All notable changes are recorded here. Versions follow [Semantic Versioning](https://semver.org/) while the CLI is pre-1.0.

## Unreleased

- Fail closed on invalid environment overrides; preserve intentionally empty config lists and return `2` for all diff validation failures.
- Refuse root agent identities on every platform and normalize numeric uid/gid values before policy checks. Run pi, startup updates, and shells only after dropping privileges/capabilities; use `/opt/pi` for unprivileged npm updates.
- Test the production launcher/entrypoint privilege profile, workspace writing, updates, and allowlist identity separation on Linux and macOS, not just stricter bare firewall probes.

- Preserve saved originals if selective-restore rollback fails, the destination reappears, or a signal leaves the swap's commit uncertain; print the recovery path.
- Refuse incomplete backup locks and serialize stale-owner recovery with an ownership recheck; never reclaim a lock merely because its PID has not been written yet.
- Correct diff additions against empty backups, preserve trailing newlines in symlink targets, and return `2` for comparison errors (`1` remains changes only).
- Preserve newline-containing parent components during selective restore; add deterministic recovery-failure and concurrency regression tests.
- Clarify backup consistency limits, per-selection restore transactions, and interrupted-recovery instructions.
- Add Debian 12/13 launcher/recovery CI alongside existing Linux/macOS coverage; use Debian-first installation guidance with a current Docker Engine and Buildx plugin.
- Simplify the README and guides, add a configuration reference, and align help text with attachment, shell-network, cleanup, timeout, and logging behavior.

## [0.6.1] - 2026-10-25

Security and correctness release; no new configuration is required.

### Fixed

- Prevent host filename glob expansion in allowlists, package lists, environment passthrough, and Docker arguments.
- Reject allowlist ports other than 80/443 instead of accepting rules the firewall could never implement; align hostname validation between launcher and sidecar.
- Prevent an agent running as uid 65532 from inheriting the sidecar's unrestricted-network uid.
- Remove test-only firewall/upstream bypass flags from production sidecar builds; test hooks now require an explicit Cargo feature.
- Remove unnecessary `SETPCAP`; verify that the Linux agent has no capabilities after its privilege drop.
- Make sidecar readiness restart-safe with a fresh `/run` tmpfs, a read-only root filesystem, and stale-marker removal.
- Flush namespace firewall chains after installing deny policies, preventing duplicate rules on restart.
- Reject non-public IPv4/IPv6 upstream ranges more completely; tighten malformed TLS SNI and HTTP authority/header parsing.
- Include all persisted container settings in resume compatibility. Resource, config-volume, Docker-argument, and environment changes can no longer resume a stale container.
- Refuse to replace an unrelated container that collides with a sidecar name; clean up sidecars after failed creation and headless runs on signals.
- Use an explicit timeout marker, stop active headless containers on signals, and write run manifests atomically.
- Serialize concurrent backups, reject measurement failures, enforce private backup directories, commit archives only after complete metadata, and prune run/orphan metadata with their archives.
- Compare content, file type, modes, and symlink targets in `sapi diff`; never recursively follow symlinks. `--full` diffs regular files only.
- Validate archive shape, stage restores, refuse destination-symlink traversal, and swap complete selected paths into place. A selected directory now replaces that directory exactly rather than merging it.
- Preserve empty environment overrides and `#` in config paths; reject extra command arguments.
- Label all session volumes and remove headless/orphan session volumes with `sapi rm`.
- Make installer/upgrade replacement atomic and never follow the destination symlink. Default installs use a release tag rather than mutable `main` (`SAPI_REF=main` opts into development).

### Documentation and CI

- Correct host-write, reproducibility, restore, and security-boundary documentation; document shared-config trust and dangerous escape hatches.
- Add private security reporting, this changelog, dependency policy, and pinned GitHub Actions.
- Run all no-Docker checks on Linux and macOS, and real Docker/firewall smoke tests on both platforms.

## [0.6.0] - 2026-10-25

- Add `sapi shell`: a hardened shell in `/pi-sessions`, with `/pi-config` and headless-run sessions beside it.
- Join a running agent or use an ephemeral, network-disabled container.

## [0.5.0] - 2026-10-25

- Add the opt-in Rust egress allowlist sidecar with fake DNS, TLS-SNI/HTTP-Host filtering, connect-by-name, non-public upstream refusal, decision logs, and pinned image/source provenance.

## [0.4.0] - 2026-10-25

- Add user-level package and Dockerfile-fragment toolchain customization with content-derived image tags.

## [0.3.0] - 2026-10-25

- Add headless `sapi run`, resource ceilings, `sapi diff`, selective restore, run manifests, and the backup/run/diff/restore workflow.

## [0.2.0] - 2026-10-25

- Add safer mode, verified external backups, persistent typed configuration, backup listing, and non-destructive restore.

## [0.1.0] - 2026-10-25

- Initial release: one-file installer/launcher, per-directory Docker isolation, persistent config/sessions, Linux uid mapping, documentation, and CI.

[0.6.1]: https://github.com/sapiensmalti/sapi/releases/tag/v0.6.1
[0.6.0]: https://github.com/sapiensmalti/sapi/releases/tag/v0.6.0
[0.5.0]: https://github.com/sapiensmalti/sapi/releases/tag/v0.5.0
[0.4.0]: https://github.com/sapiensmalti/sapi/releases/tag/v0.4.0
[0.3.0]: https://github.com/sapiensmalti/sapi/releases/tag/v0.3.0
[0.2.0]: https://github.com/sapiensmalti/sapi/releases/tag/v0.2.0
[0.1.0]: https://github.com/sapiensmalti/sapi/releases/tag/v0.1.0
