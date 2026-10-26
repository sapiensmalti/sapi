# Network allowlist

Network access is **unrestricted by default**. Opt-in allowlist mode restricts the agent's external connections to allowed hostnames over HTTP on port 80 and TLS on port 443. It does not inspect encrypted content or make an allowed service trustworthy.

**Root-agent limitation:** the current uid-0 setup, including the macOS default, retains identity-changing capabilities. Do not rely on this allowlist against hostile code in that configuration. See [root agents and allowlisting](security.md#root-agents-and-allowlisting).

```sh
sapi config set allow "@providers @github @npm"
sapi config set network allowlist
sapi
sapi netlog                         # print available sidecar logs, then exit
```

To return to unrestricted networking: `sapi config set network full`. Settings affect subsequent agent starts, not agents already running. Stop/restart an agent to apply a changed policy; its session volume is kept.

## Syntax and presets

| Entry | Matches |
|---|---|
| `api.anthropic.com` | Exactly that hostname on 80 and 443 |
| `*.github.com` | Subdomains, but not `github.com` itself |
| `registry.example:443` | That hostname on 443 only |
| `@providers` | The provider preset below |

Entries are comma/space-separated. Explicit ports can only be `80` or `443`. Names and presets are validated by the launcher and sidecar; wildcards are not expanded against local filenames. Quote lists and wildcards in shell commands.

| Preset | Hosts |
|---|---|
| `@providers` | api.anthropic.com, api.openai.com, openrouter.ai, generativelanguage.googleapis.com, api.mistral.ai, api.groq.com, api.x.ai, api.deepseek.com, api.together.xyz, api.fireworks.ai, api.cerebras.ai, api.cohere.com, api.perplexity.ai |
| `@github` | github.com, \*.github.com, \*.githubusercontent.com, codeload.github.com, ghcr.io, \*.pkg.github.com |
| `@npm` | registry.npmjs.org, \*.npmjs.org, nodejs.org |
| `@pypi` | pypi.org, files.pythonhosted.org, \*.pypi.org |
| `@cargo` | crates.io, static.crates.io, index.crates.io, static.rust-lang.org |
| `@go` | proxy.golang.org, sum.golang.org |
| `@debian` | deb.debian.org, security.debian.org |
| `@huggingface` | huggingface.co, \*.huggingface.co, cdn-lfs.huggingface.co |

The default is `@providers` only. Presets are convenience lists, not coverage of every pi provider, login flow, redirect, or package CDN. Add the actual required hostnames; keep wildcards narrow. Policy is visible in the sidecar's `EGRESS_ALLOW` environment via `docker inspect`.

## Enforcement

The agent shares a network namespace with a separate Rust sidecar, `NAME-egress`. It receives no `NET_ADMIN` or `NET_RAW` capability. Unlike an advisory `HTTPS_PROXY` variable, the namespace firewall applies even if a client ignores proxy settings.

1. The sidecar installs default-drop firewall rules before the agent starts. Agent DNS and TCP 80/443 traffic are redirected to local listeners; other external traffic is dropped. IPv6 agent egress is blocked.
2. DNS is answered locally, not forwarded: an allowed A query receives the synthetic address `198.18.0.1`, a denied name receives NXDOMAIN, and allowed AAAA queries receive no address.
3. TLS SNI or the HTTP Host/request-target hostname is checked against the policy. The relay resolves and connects to that name, not to the client's chosen destination IP. Non-public upstream addresses are refused.
4. The sidecar drops to uid 65532 and checks that it cannot regain root. It publishes readiness only after firewall/listener setup and the privilege drop; sapi waits before starting/resuming the agent.

Loopback remains available. The sidecar's own uid is exempt so it can resolve/connect upstream; sapi refuses to run the agent as uid 65532. The sidecar runs read-only, with a fresh 1 MiB `/run` tmpfs, a 256 MiB memory limit, and a 256-process limit. Firewall chains are reset on restart and stale readiness is removed.

## Logs

`sapi netlog [NAME]` prints available sidecar logs; it does not follow them. Without a name, it selects a sidecar for the current workspace. Specify the agent name when several exist. For live logs, use `docker logs --follow NAME-egress` from the host.

Parsed DNS/TLS/HTTP decisions are JSON lines containing the available hostname, protocol, reason, upstream, byte counts, and timing. Successful TLS/HTTP relay records appear when the connection ends. Startup diagnostics can also appear. Headless-run sidecars are removed when the run finishes; sapi does not save a host-side network-log archive.

**Firewall-dropped packets do not produce per-attempt JSON records.** These logs are not a complete traffic capture or an immutable audit trail.

## Operational limits

- **Allowed hosts remain data channels.** TLS is end-to-end; an agent can send secrets to an allowed service. Use least-privilege credentials and only the hosts the task needs.
- **SSH, QUIC, and arbitrary ports are unavailable.** Use HTTPS Git remotes instead of SSH. Host allowlisting does not configure Git authentication; passing `GH_TOKEN` alone does not make Git use it.
- **Pi self-update requires the literal `@npm` preset.** Without it, sapi skips the update attempt, even if you manually listed npm's hosts. `SAPI_AUTO_UPDATE=0` also disables it.
- **Published development-server ports are not supported** in allowlist mode. Port publishing would belong to the sidecar, and inbound traffic is filtered. Use full mode for that workflow.
- **Some TLS clients may be refused.** A parseable hostname is required; connections without usable SNI, including some encrypted-ClientHello configurations, cannot be authorized. Raw-IP URLs without a hostname are not supported.
- **Shells are separate behavior.** A shell joining a running agent inherits its network. A temporary `sapi shell --net` uses Docker's default network, not this allowlist. See [sessions and shells](recovery.md#sessions-and-shells).
- **Image builds are outside this policy.** Docker pulls and build-time apt/npm downloads happen before the agent joins the filtered namespace. The allowlist is not a host-wide firewall.
- **No bandwidth cap or container-escape guarantee.** Byte counts are logged, not limited. Docker/kernel trust remains part of the [security model](security.md).

## Sidecar source and verification

The published sidecar is digest-pinned; its matching source archive is checksum-pinned. `SAPI_EGRESS_BUILD=1 sapi` builds from that source locally instead of pulling the image. This still requires network access for build inputs. `SAPI_EGRESS_IMAGE` is an explicit trust override. See [the release workflow](../.github/workflows/egress-image.yml) and [`egress/`](../egress).

CI tests launcher/recovery behavior in Debian 12/13 userspaces without a Docker socket. Separate real Docker smoke tests on Linux and macOS exercise allowed/denied destinations, firewall permissions, restart readiness, read-only sidecar storage, and logs. Rust tests cover parsers, address filtering, firewall rules, and relays. Test-only bypass flags are excluded from the production build.
