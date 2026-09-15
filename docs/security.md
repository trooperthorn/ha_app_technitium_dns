# Security

## Security rating (apps-cards-hacs.md section 1.10 math)

Base rating: 5 (of 6).

| Setting | Effect | This app |
| --- | --- | --- |
| `ingress: true` | +2 | Set. |
| `auth_api` | +1 (overridden by ingress) | Not set. |
| custom `apparmor.txt` | +1 | Shipped (`technitium_dns/apparmor.txt`); see "AppArmor profile" below. |
| `apparmor: false` | -1 | Not set. |
| `privileged:` capabilities, `kernel_modules` | -1 | Not set. |
| `hassio_role: manager` | -1 | Not set (`default`). |
| `host_network: true` | -1 | Not set. See "Why not host_network" below. |
| `hassio_role: admin` | -2 | Not set. |
| `host_pid: true` | -2 | Not set. |
| `full_access: true` | rating forced to 1 | Not set. |
| `docker_api: true` | rating forced to 1 | Not set. |

Net: 5 (base) + 2 (`ingress: true`) = 7, clamped to the documented 1-6 scale's
maximum, so this app's declared rating is 6 out of 6 -- the ceiling. Ingress
is the only modifier this app trips.

## Additional encrypted-DNS ports

`technitium_dns/config.yaml` also declares `853/tcp` (DoT), `443/tcp` (DoH),
and `443/udp` (DoQ), each defaulted to `host: null` (not mapped). apps-cards-
hacs.md's rating table does not price declared-but-unmapped ports
differently from ports mapped by default; the rating impact here is nil
either way. The actual security posture is: until an operator maps one of
these host ports and separately enables the corresponding protocol with a
certificate in Technitium's own console, nothing listens there and no
additional surface exists. Once enabled, that port carries the same
DNS-resolver trust boundary as port 53 itself, plus whatever the operator's
chosen TLS certificate is trusted for. See docs/decisions.md and
docs/operations.md.

## Why not host_network

`host_network: true` costs -1 on this same scale and grants the container
the host's entire network namespace, not just the ports the app needs. This
app's stated purpose is being a DNS resolver for the LAN, which needs port 53
(tcp and udp) reachable, and nothing else. `ports: {53/tcp: 53, 53/udp: 53}`
grants exactly that, at no rating cost, using the mechanism the same
apps-cards-hacs.md section documents as the ordinary way apps expose a port.
`host_network` was used in `ha_app_kiosk` because that app needs its own
127.0.0.1 to resolve to the host's loopback so it can reach Home Assistant
Core directly; this app has no equivalent requirement, so it does not carry
that same cost.

## Ingress-only web console

`ingress: true` with `ingress_port: 5380` puts the entire web console behind
Home Assistant's own authentication. Per apps-cards-hacs.md section 1.12,
only connections from `172.30.32.2` (the Ingress gateway) reach the app, and
the app itself performs no authentication of its own for that path -- Home
Assistant already authenticated the user before proxying the request.
`run.sh` sets `DNS_SERVER_WEB_SERVICE_REVERSE_PROXY_ADDRESSES=172.30.32.2` so
Technitium's own reverse-proxy trust check accepts the forwarded requests,
and `DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS=false` because Ingress already
terminates TLS; running a second, self-signed TLS layer behind it would add
nothing an attacker on the loopback path couldn't already see, and would add
a second certificate operators would have to manage for no benefit. Port
5380 itself is not mapped to any host port; see `technitium_dns/config.yaml`.

## First-run admin password

`DNS_SERVER_ADMIN_PASSWORD` and `DNS_SERVER_ADMIN_PASSWORD_FILE` are read by
Technitium only on the very first start, before any configuration file
exists (verified against `DockerEnvironmentVariables.md` in the upstream
repository, read 2026-09-15). This app never sets a fixed default password.
`run.sh` generates a random 24-character password into
`/data/admin_password` (mode 600, inside this app's own persistent data
directory) and passes it via `DNS_SERVER_ADMIN_PASSWORD_FILE`, then logs it
once so the operator can capture it. See `technitium_dns/DOCS.md` for
retrieval and docs/operations.md for what happens if it is missed.

### Labeled limitation: the `admin_password` option, if set, is plaintext

If an operator sets the `admin_password` option in this app's own
configuration screen instead of leaving it blank, that value is honored on
first start, but Supervisor stores every app option -- including this one --
in plaintext at `/data/options.json` for the life of the install. This is a
Home Assistant apps platform convention this app cannot override (apps read
their configuration from that file; there is no per-option encryption
mechanism documented in apps-cards-hacs.md). This app does not hide that
fact: `run.sh` logs a warning when this path is taken, `translations/en.yaml`
states it in the option's own description, and this file states it here.
The random-password default exists specifically so an operator does not have
to take this path at all.

## AppArmor profile

`technitium_dns/apparmor.txt` replaces Home Assistant's generic default app
profile. It narrows the container's Linux capabilities to the ones this app
actually uses (`net_bind_service` for port 53, plus `chown`/`dac_override`/
`fowner`/`setuid`/`setgid` for the first-run ownership work under `/data`)
and explicitly denies capabilities and operations this app never needs
(`sys_admin`, `sys_module`, `sys_ptrace`, `sys_rawio`, `net_admin`, `net_raw`,
`dac_read_search`, `mount`, `umount`, `pivot_root`, tracing other processes).
It restricts network address families to `inet`/`inet6` stream and dgram
only -- no raw or packet sockets.

File mediation in that profile is left broad (`file,`) rather than an exact
path whitelist. This is a deliberate, labeled tradeoff: the .NET runtime's
own file access pattern (JIT/ReadyToRun caches, ICU data, temp files) was not
traced against a live running container, and a wrong narrow whitelist fails
closed -- it would silently break DNS resolution for the whole household
rather than degrade gracefully. Capability and network-family restrictions
do not carry that risk, because they can be stated directly from Technitium's
and .NET's own documented behavior (runs as root, binds UDP/TCP port 53, no
raw sockets) without needing to observe the running container first.

The profile enforces (no `complain` flag) as of 2026-09-15, at Sean's
explicit direction, without the live-install verification described below
having actually been performed. A CI smoke test added the same day (see
`.github/workflows/test.yml`) runs the built image with a plain `docker
run` and confirms it starts, reports healthy, and resolves DNS -- but a
plain `docker run` never attaches this custom profile at all; only Home
Assistant Supervisor does that, by loading `apparmor.txt` and applying it
through the AppArmor LSM when it installs the app. So enforcement has not
been observed against a real install, and this is a known, accepted gap,
not a completed verification. See docs/decisions.md, "AppArmor: enforced
without live verification".

If this app fails to start, fails first-run initialization under `/data`,
or fails to bind port 53 after installing it, check
`journalctl _TRANSPORT="audit" -g 'apparmor="DENIED"'` on the Home Assistant
host for entries naming profile `technitium_dns` before assuming an
unrelated cause. If this profile is the problem, reintroduce the `complain`
flag in `apparmor.txt`, redeploy, and use the same `journalctl` command with
a real install running to find and add whatever it's missing, rather than
broadening `file,` or capability grants speculatively. See docs/operations.md
for the full procedure this was meant to have gone through first.

## Container user: unverified / not changed

Whether the upstream `technitium/dns-server` image drops root privileges was
checked directly: the upstream Dockerfile
(`TechnitiumSoftware/DnsServer/master/Dockerfile`, fetched 2026-09-15) has no
`USER` directive after its `FROM mcr.microsoft.com/dotnet/aspnet:10.0` line,
and its `ENTRYPOINT` runs `dotnet` directly with no privilege-drop step
visible in the file. The process therefore runs as root inside the
container by default, and this is confirmed, not unverified. What remains
unverified is whether a non-root user exists in the image that could be
selected with a `USER` directive in this app's own Dockerfile without
breaking Technitium's own file ownership expectations under `/etc/dns`
(mapped here to this app's `/data` subdirectory); this app does not attempt
that without confirming it first, and runs the container as the image's
default (root) rather than guessing at an unverified non-root UID.

## Base image trust boundary

This app builds `FROM technitium/dns-server:15.4.0`, pinned by tag and
digest (see `technitium_dns/Dockerfile`). It does not re-audit Technitium's
own source or its base .NET runtime image. A vulnerability in Technitium
itself, in the .NET runtime, or in the upstream image's own dependencies is
outside what this app's own CI (which scans the layers this Dockerfile
adds) can catch. Operators should track Technitium's own release notes and
CVE disclosures independently.

## Command surface

This app has no control API of its own (unlike `ha_app_kiosk`'s
`rest_server.py`): every administrative action goes through Technitium's own
web console and its own authentication, reached only via Ingress as
described above. There is no second command surface for this app to secure.
