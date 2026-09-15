# Decisions

Dated entries for choices made in this repository and why. See
`technitium_dns/CHANGELOG.md` for the release history.

## Fresh build FROM the upstream Technitium image, not the Home Assistant base image (2026-09-15)

Technitium ships its own .NET runtime and application inside
`technitium/dns-server`; there is nothing this app adds to the container
besides first-run password seeding and the option-to-environment
translation in `run.sh`. Building `FROM ghcr.io/home-assistant/base` and
installing Technitium's own .NET runtime on top would duplicate what
upstream already builds and tests, with no security or maintenance benefit.

## Pinned tag and digest (2026-09-15)

`technitium_dns/Dockerfile` pins
`technitium/dns-server:15.4.0@sha256:df7d90ef0f7b6fff6916d291a7022cd902290cc31c3141d4158b6c375a641b41`,
read from the Docker Hub tag manifest on 2026-09-15. `15.4.0` was the newest
version-numbered tag on Docker Hub at that time; `latest` was deliberately
not used so a Supervisor rebuild of this app's image cannot silently pick up
a new upstream release without a reviewed bump to this Dockerfile. Re-verify
by checking `https://hub.docker.com/r/technitium/dns-server/tags` for a
newer version tag and its digest before bumping.

## Web console: Home Assistant Ingress only, not a host port (2026-09-15)

Sean's answer to the web UI exposure question. `config.yaml` sets
`ingress: true` and `ingress_port: 5380`; port 5380 is never listed under
`ports:`. Ingress terminates TLS and authenticates the viewer as a Home
Assistant user before the request reaches this app, which is a stronger
boundary than anything this app could add on its own. `run.sh` also seeds
`DNS_SERVER_WEB_SERVICE_REVERSE_PROXY_ADDRESSES=172.30.32.2` (Home
Assistant's documented Ingress gateway address, apps-cards-hacs.md section
1.12) so Technitium's own reverse-proxy trust check accepts
Ingress-forwarded requests, and sets
`DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS=false` since Ingress, not Technitium,
terminates TLS for this path.

## Explicit `ports:` mapping instead of `host_network` (2026-09-15)

Sean's answer to the network role question: this app is meant to act as a
production DNS resolver for LAN clients, which requires port 53 (tcp and
udp) actually reachable from the network, not just from the Home Assistant
host. `host_network: true` was rejected in favor of an explicit `ports:`
mapping (`53/tcp: 53`, `53/udp: 53`, host side left as `null` so an
installer can choose a different host port) because `host_network` grants
the container the host's entire network namespace, not just the one port
this app needs. Per apps-cards-hacs.md section 1.10's security rating
criteria, `host_network: true` is one of the factors that lowers an app's
rating; an explicit `ports:` list with no `host_network` and no
`full_access` keeps the blast radius of a compromised container to the one
port it was actually granted. `full_access` is not set for the same reason.

## First-run admin password: generated into a file, not a fixed default (2026-09-15)

Sean's design answer. `DNS_SERVER_ADMIN_PASSWORD` and
`DNS_SERVER_ADMIN_PASSWORD_FILE` are upstream environment variables read
only on Technitium's first start, before any configuration file exists.
Putting a password (fixed or operator-typed) into `config.yaml`'s
`options` would put it in Supervisor's plaintext `options.json` for the
life of the install with no in-app way to rotate it. Instead, `run.sh`
generates a random 24-character password on first start, writes it to
`/data/admin_password` (mode 600, inside this app's own data directory),
and logs it once. If the operator did set `admin_password` anyway, `run.sh`
honors it once and logs a warning about the plaintext-storage tradeoff,
rather than silently ignoring the option.

## `stage: experimental` for the first release (2026-09-15)

This app has not yet been run as a household DNS resolver in the field.
Promote to `stable` only after a real installation has run it as the
household resolver without a regression; see `technitium_dns/config.yaml`.

## No automatic "wipe and reseed" option (2026-09-15)

Upstream's `DNS_SERVER_*` environment variables only take effect on a truly
first start, before `/etc/dns` (mapped here to `/data/etc-dns`) contains a
configuration file. Once Technitium has written its own config, changing an
option in this app's UI has no effect; the only way to make a first-start
variable apply again is to delete the persisted configuration, which is
destructive (it also deletes zones and other admin-configured state, not
just the options this app manages). This app does not build an automatic
toggle for that: the consequence is disproportionate to the convenience,
and an operator who genuinely wants to reseed should do it deliberately.
See `docs/operations.md`.

## Security audit findings and fixes (2026-09-15)

A post-scaffold security audit found `run.sh` calling `bashio::config` and
`bashio::log.*`, which do not exist in this image: `bashio` is a shell
library only present in Home Assistant's own Alpine base images, and this
app is built `FROM technitium/dns-server`, Microsoft's `dotnet/aspnet`
Debian-based image, on purpose (see "Fresh build" above). As shipped, the
container would have failed at startup with `bashio: command not found`
before ever reaching Technitium. Fixed by rewriting `run.sh` to read
`/data/options.json` directly with `jq` (added to `technitium_dns/Dockerfile`
alongside `curl`) and to log with plain timestamped `echo`/`printf` instead
of `bashio::log.*`. The behavior `run.sh` implements did not change, only
how it reads options and logs.

Confirmed during the same audit: DNS resolution uses the standard port 53
(tcp and udp), mapped directly from container to host with no offset or
alternate port, so LAN clients and devices resolve against this server the
same way they would against any other DNS server, with no non-standard port
configuration required on the client side. See `technitium_dns/config.yaml`
`ports:` and docs/operations.md, "Port 53 conflicts", for the one case this
does not cover (something else on the host already holding port 53).

## Custom AppArmor profile, shipped in complain mode (2026-09-15)

Sean asked for AppArmor to be as secure as possible. Home Assistant's
generic default app profile applied by default already provides baseline
confinement, but a custom `technitium_dns/apparmor.txt` (profile name
matching the `slug`) narrows Linux capabilities to what this app actually
uses (`net_bind_service` for port 53, plus the ownership-related
capabilities `run.sh` and Technitium's first-run initialization need under
`/data`), explicitly denies capabilities and operations this app has no
legitimate use for (`sys_admin`, `sys_module`, `sys_ptrace`, `sys_rawio`,
`net_admin`, `net_raw`, `dac_read_search`, `mount`, `umount`, `pivot_root`,
tracing other processes), and restricts network address families to
`inet`/`inet6` stream and dgram only.

File mediation in the profile stays broad (`file,`) rather than an exact
path whitelist, because the .NET runtime's file access pattern was not
traced against a live running container and a wrong narrow whitelist fails
closed, silently breaking DNS resolution for the household. This is stated
explicitly in `apparmor.txt` and `docs/security.md`, not left implicit.

The profile ships with the `complain` flag rather than enforcing
immediately, because it has not been verified against a live installation
in this session (no running Home Assistant instance with this app installed
was available to test against). `complain` mode still earns the
apps-cards-hacs.md section 1.10 `+1` rating for shipping a custom profile,
logs any denial instead of blocking it, and gives Sean a concrete
verification step (`docs/operations.md`, "Verifying and enforcing the
AppArmor profile") to run before switching it to actual enforcement.
Shipping straight to enforce without that verification was rejected: an
untested enforce-mode profile that turns out to be wrong would fail closed
and take down DNS for the household with no warning.

## Standard ports exposed for encrypted DNS, off by default (2026-09-15)

Sean asked for the DNS ports clients see to be documented and for standard
encrypted-DNS protocols (DoT, DoH, DoQ) to be supportable without clients
needing a non-standard port. `technitium_dns/config.yaml` now maps `853/tcp`
(DoT), `443/tcp` (DoH), and `443/udp` (DoQ) alongside the always-on
`53/tcp`/`53/udp`, all at their standard, well-known port numbers so a
client's own default DoT/DoH/DoQ configuration needs no custom port entered.

Unlike the plain-DNS options, none of these three has a first-run
environment variable in Technitium (confirmed against
`DockerEnvironmentVariables.md`, read 2026-09-15): enabling a protocol and
supplying its TLS certificate is done afterward in Technitium's own web
console, not through this app's options. Because of that, and because an
open 853/443 port with nothing configured behind it is still attack surface
for no benefit, all three default their host-side mapping to `null` (not
mapped) rather than mapping them on by default the way `53/tcp`/`53/udp`
are. An operator turns one on deliberately: map the port in this app's
Network screen, then configure the certificate and protocol in Technitium's
console. See docs/operations.md, "Enabling encrypted DNS for clients", for
the exact steps, and `technitium_dns/DOCS.md` for the client-facing port
table.

## Runtime overlay to clear High CVEs (2026-09-15)

The repository's Security workflow (Grype, `--fail-on high --only-fixed`)
failed on the first two pushes with six High-severity GHSA advisories
against `Microsoft.NETCore.App.Runtime.linux-x64` 10.0.9, all fixed in
10.0.10 or 10.0.11. `technitium/dns-server:15.4.0` (Technitium's own newest
release, published 2026-07-11, confirmed no newer tag exists as of
2026-09-15) is built on `mcr.microsoft.com/dotnet/aspnet:10.0` and bundles
that vulnerable 10.0.9 runtime; Technitium has not published a release
against a newer runtime yet, so bumping the pinned Technitium tag cannot fix
this on its own.

Fixed by adding a build stage that pulls
`mcr.microsoft.com/dotnet/aspnet:10.0.12` (Microsoft's own newest patch as of
2026-09-15, digest `sha256:6a94333d37514e385650a3c81a55e5350b67253dbe136e9cf17e499c35606a8c`,
confirmed via the MCR registry API) and copies its
`/usr/share/dotnet/shared/Microsoft.NETCore.App` and
`/usr/share/dotnet/shared/Microsoft.AspNetCore.App` directories over the
Technitium image's own, then explicitly removes the old `10.0.9` version
folders from both (a plain `COPY` over an existing directory adds files, it
does not delete the ones already there). This patches the .NET runtime in
place without touching Technitium's own application under
`/opt/technitium`. It has not been verified by an actual build in this
session (no local Docker/Grype available); the next CI run on this
repository's Security workflow is the real verification, and this should be
re-examined if that run does not come back clean. This is documented as a
standing exception to remove, not a permanent pattern: once Technitium
publishes a release built against a runtime newer than 10.0.9, drop this
overlay stage and go back to pinning Technitium's image alone. See
`technitium_dns/Dockerfile` for the implementation.

## AppArmor: enforced without live verification (2026-09-15)

`technitium_dns/apparmor.txt` shipped with a `complain` flag (see "Custom
AppArmor profile, shipped in complain mode" above) specifically because
enforcing an untested custom profile can fail closed and take down DNS for
the household with no clear error. Sean asked to enforce it now that it's
"verified"; the actual verification available in this session was a CI
smoke test (`.github/workflows/test.yml`, added the same day) that runs the
built image with a plain `docker run` and confirms it starts, reports
healthy, and resolves DNS. That smoke test does not exercise this profile
at all: a plain `docker run` never attaches a custom AppArmor profile: only
Home Assistant Supervisor does that, by loading `apparmor.txt` and applying
it via the AppArmor LSM when it installs the app.

This was surfaced explicitly before making the change, not silently
assumed. Sean's answer, given that gap, was to enforce anyway rather than
wait for a live Supervisor install to check
`journalctl _TRANSPORT="audit" -g 'apparmor="DENIED"'` against, so the
`complain` flag was removed from `technitium_dns/apparmor.txt` on that
explicit instruction. This is an accepted risk, not a completed
verification: if Technitium or `run.sh` need something this profile denies,
the first real install is where that will surface, most likely as the app
failing to start or failing first-run initialization rather than as an
obvious AppArmor error. See docs/operations.md, "AppArmor: enforcing without
live verification, and how to recover", for what to do if that happens.

## Ingress panel blocked by Technitium's own frame-blocking headers (2026-09-15)

After Sean installed this app on a real Home Assistant host, the Ingress
sidebar panel showed "refused to connect" when clicked, even though the app
itself was healthy: `curl http://127.0.0.1:5380/` from inside the container
returned a clean `200`, and no AppArmor denials appeared anywhere. Two
earlier theories (first checked and ruled out) were an AppArmor denial and
a Kestrel/.NET keep-alive incompatibility with Supervisor's aiohttp-based
Ingress proxy suggested by Supervisor's own log
(`Stream error ... Cannot write to closing transport`, sourced from
home-assistant/supervisor issues #5248 and the matching community thread).
Both were wrong.

The actual cause, found by comparing against
`staerk-ha-addons/addon-technitium-dns` (an existing community add-on for
the same server, which Sean asked to compare against precisely because this
symptom needed a working reference to diagnose against): Technitium's own
web console sends `X-Frame-Options: DENY` and a Content-Security-Policy
with `frame-ancestors 'none'`. Home Assistant Ingress embeds every app's UI
in an iframe on the HA frontend's own origin; a page that refuses all
framing makes the browser refuse to render it there, and Chrome reports
that specific failure as the page "refused to connect" -- which reads as a
network failure but is actually a framing policy rejection. This explains
every piece of evidence: the app was never broken, only embeddable-in-an-
iframe was.

`staerk-ha-addons/addon-technitium-dns` solves this with an nginx reverse
proxy in front of Technitium that strips those two headers and replaces
them with `X-Frame-Options: SAMEORIGIN` and a CSP allowing
`frame-ancestors 'self'` -- same-origin framing only, not framing removed
outright, so cross-origin clickjacking protection is preserved. This app
adopts the same fix: `technitium_dns/nginx.conf` defines that proxy,
listening on 5380 (this app's declared `ingress_port`) and forwarding to
Technitium on `127.0.0.1:5381` (moved off 5380 and bound to loopback only,
see `run.sh`). `DNS_SERVER_WEB_SERVICE_REVERSE_PROXY_ADDRESSES` changed
from the Ingress gateway's own address (`172.30.32.2`) to `127.0.0.1`,
because nginx, not the Ingress gateway, is now what connects to Technitium
directly.

That reference add-on runs full s6-overlay process supervision (a
dedicated `ingress` service, restarted independently if it dies) and
`host_network: true` with a dynamic `ingress_port: 0`, read at runtime via
`bashio::app.ingress_port`. This app does not adopt either: it keeps its
fixed `ingress_port: 5380` and its explicit-`ports:`-instead-of-
`host_network` design (see "Explicit ports: mapping instead of
host_network" above), and starts nginx as a plain backgrounded process in
`run.sh` before `exec`-ing Technitium (which stays PID 1, so it still gets
a direct, timely SIGTERM on shutdown). The accepted tradeoff: if nginx
itself crashes, nothing in this container restarts it automatically, and
Technitium keeps running underneath with the Ingress panel now broken
again in the same way. The Dockerfile's `HEALTHCHECK` (curls
`127.0.0.1:5380`, i.e. nginx) would then start reporting unhealthy, which
is how an operator would notice. Adopting full s6-overlay for proper
supervision of both processes was considered and deferred as
disproportionate to a two-process container; revisit if nginx reliability
becomes an actual observed problem, not a theoretical one.

### Migration for the install already running when this landed

Sean's install had already completed Technitium's first start under the
old configuration (port 5380, direct, before this fix) by the time this was
found. Because Technitium's `DNS_SERVER_*` environment variables only take
effect before a configuration file exists (see "No automatic 'wipe and
reseed' option" above), the persisted config from that first run would
still tell Technitium to listen on 5380 -- directly conflicting with nginx,
which this fix also binds to 5380. Since nothing had actually been
configured through that first, broken run (the web console was never
reachable to configure anything), the fix for that specific install is the
already-documented destructive path: delete the persisted config under
`/data/etc-dns` and restart so Technitium goes through first start again,
this time seeded with the nginx-fronted values. See docs/operations.md.

## Container user not changed (2026-09-15)

Technitium's own Dockerfile
(`https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/Dockerfile`,
read 2026-09-15) has no `USER` directive, so the process runs as root
inside the upstream image by default; this is verified. Whether upstream's
own entrypoint drops privileges internally after starting as root is not
shown in the Dockerfile alone and was not independently verified this
session. This app does not add a `USER` directive of its own, because
`/etc/dns` is owned by root in the upstream image and switching users here,
without verifying how upstream's own first-run file creation behaves,
risked breaking that first-run path in an unverified way. See
`docs/security.md`, "Container user: unverified / not changed".
