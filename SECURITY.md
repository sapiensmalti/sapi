# Security policy

## Report privately

Please use [GitHub's private security advisory form](https://github.com/sapiensmalti/sapi/security/advisories/new). **Do not open a public issue with reproduction details, credentials, or an exploit.** Include the sapi version, OS, Docker provider/version, a minimal reproduction, and the security impact. Remove tokens and personal paths from logs.

If private reporting is unavailable, open an issue containing only a request for a private contact channel; do not include the finding itself.

## Scope

In scope:

- Escaping the workspace/container boundary without an explicit user override.
- Bypassing the opt-in egress allowlist or changing its firewall from the agent.
- Reading or writing unintended host paths through backup, diff, restore, shell, or upgrade.
- Silent failure of a safety setting, or an unsafe fallback after a failed backup/firewall.
- Supply-chain weaknesses in sapi's own installer, workflows, or published sidecar.

The following are outside the container-boundary guarantee, but documentation corrections and defense-in-depth improvements are still welcome:

- A malicious Docker daemon, Linux kernel, container runtime, base image, npm package, or host user with Docker access.
- Deliberate use of `SAPI_DOCKER_ARGS`, `SAPI_IMAGE`, `SAPI_EGRESS_IMAGE`, or a user Dockerfile fragment to widen access.
- Damage to the one directory the user intentionally gave the agent (use safer mode and git).
- An agent reading credentials it needs to perform its task, or sending data to an allowed model/provider host.

Read [the security model](docs/security.md) and [network limits](docs/network.md) before assuming a guarantee.

## Supported versions

Security fixes are made on `main` and released as the newest tagged version. Upgrade with `sapi upgrade`; pin installations to a tag when your environment requires change control. There is currently no separate long-term-support branch.

## Disclosure

We will investigate, reproduce where possible, develop a fix and regression test, and coordinate disclosure with the reporter. No response-time or bounty promise is implied.
