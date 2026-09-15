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

## nginx kept, not switched to lighttpd/Caddy/HAProxy (2026-09-15)

Sean asked whether lighttpd or another server would be a better choice than
nginx for the Ingress reverse proxy. Kept nginx, switched to the leaner
`nginx-light` Debian package rather than switching software: `nginx-light`
was confirmed (Debian package listing, read 2026-09-15) to still include
the proxy, map, and headers modules this config actually uses (`proxy_pass`,
the `map` block for the WebSocket `Upgrade` header, `proxy_hide_header`/
`add_header`), with a smaller footprint (and so a smaller attack surface,
relevant since this container runs everything as root) than the full
`nginx` package this app shipped with initially.

The concrete alternatives and why they were not adopted instead:

- **lighttpd**: this app's specific requirement -- strip two response
  headers, add two replacements, and pass through a WebSocket upgrade for
  Technitium's live dashboard -- is proven working in CI with the current
  nginx config (see the "App image installs and starts" job). Re-doing that
  same header-strip-and-WebSocket combination in lighttpd's own module
  syntax was not verified this session, and switching a working, tested fix
  to an unverified one for an already-solved problem was judged not worth
  the risk for the stated goal (this app needs one thing done reliably, not
  a smaller binary specifically).
- **Caddy**: single static binary, memory-safe (Go), and its
  `reverse_proxy`/`header_up`/`header_down` directives can do the same job
  more concisely. Not adopted here because Debian does not carry it in the
  base repos this Dockerfile already uses via `apt-get` (verifying and
  pinning a separate binary download or third-party apt repo was
  disproportionate to swapping out a working two-header rewrite), and its
  automatic-HTTPS/ACM behavior needs explicit disabling for a plain internal
  `:5380` listener, another thing to get right and verify that nginx's
  config here already does not need to worry about.
- **HAProxy**: capable of the same header manipulation and WebSocket
  pass-through. Not adopted for the same reason as lighttpd: no verified
  benefit over the nginx config already proven in CI, for the one job this
  proxy does.

If nginx's own security posture (not this app's use of it) becomes a
specific concern later, revisit this with a real vulnerability or CVE in
hand, not as a blanket software swap.

## Web console access log for SOC audit tracking (2026-09-15)

Sean asked for web console access to be logged so it can be tracked in his
HA SOC audit work. `technitium_dns/nginx.conf` now logs every Ingress
request as one JSON line to
`/data/log/nginx/web_console_access.log`, including the Home Assistant user
identity Ingress attaches to the request after authenticating the viewer
(`X-Remote-User-Id`, `X-Remote-User-Name`, `X-Remote-User-Display-Name`;
apps-cards-hacs.md section 1.12) rather than only an IP address: every
request nginx receives comes from the Ingress gateway itself
(`172.30.32.2`), so `$remote_addr` alone would not distinguish which HA
user made a given request, while these headers do.

Retention is controlled by the new `web_console_access_log_retention_days`
option (default 90), applied on every start (unlike this app's other
options, which are first-run-only) because `run.sh` regenerates the
logrotate configuration from the current option value each time it starts,
rather than baking a fixed value into the image or writing it once during
first run. `run.sh` also starts a plain daily loop that invokes `logrotate`
itself, since this container has no cron daemon; the loop dies with the
container on stop/restart and is recreated on the next start, which is
fine because logrotate's own state file (`/data/log/nginx/logrotate.state`)
persists in `/data` across restarts.

What this does not do, stated explicitly rather than left implicit: it does
not wire this log into any specific HA SOC ingestion mechanism. How (or
whether) `ha_Int_soc` currently tails or ingests arbitrary app log files
under `/data` was not verified in this session; connecting this file as an
actual SOC data source is a task for that side, not something this app
assumes or builds for it. This app's contribution is producing a
structured, retained, per-user log at a known path; consuming it into an
audit pipeline is a separate, not-yet-done step.

## Quad9 forwarder and AD conditional zone documented as operator guidance, not app options (2026-09-15)

Sean asked for a concrete setup with Quad9 as the global forwarder and his
internal Windows AD DNS server (`10.1.23.25`) handled via a Conditional
Forwarder Zone, plus firewall rules forcing all client DNS through this app.
This is documented in `docs/operations.md`, "Example: Quad9 global forwarder
with an internal AD conditional zone" and "Forcing all client DNS through
this server (firewall/gateway rules)", rather than added as new
`config.yaml` options, for two reasons: Conditional Forwarder Zones are a
Technitium web-console feature with no first-run environment variable
equivalent (same category as the DoT/DoH/DoQ certificate setup already
documented under "Enabling encrypted DNS for clients"), and the firewall
rules live entirely outside this app's container, on Sean's gateway/UniFi
infrastructure, which this app has no ability to configure or verify.

The specific addresses (`10.1.23.25`, the `10.0.0.0/8` range) are Sean's own
environment, written into the example for concreteness; an operator with a
different internal DNS server or address range substitutes their own values
following the same zone-type/protocol pattern. The `forwarders`/
`forwarder_protocol` options in `technitium_dns/config.yaml` and their
descriptions in `translations/en.yaml` already carry the general version of
this guidance (don't set a global forwarder if you need one internal domain
resolved elsewhere; use a Conditional Forwarder Zone instead) for first-run
configuration; this decision documents the same pattern applied to an
already-running instance via the console, plus the network-enforcement half
that has no config.yaml equivalent at all.

The TCP/443 DoH gap in the firewall guidance (a Layer 4 rule cannot
distinguish DoH-over-HTTPS from ordinary HTTPS on the same port) is stated
as an open limitation, not solved: closing it needs application-layer/DPI
capability on the gateway itself, which was not verified against Sean's
specific hardware or firmware in this session.

## UCG Fiber / UniFi Network 10.6 firewall guidance verified via web research (2026-09-15)

Sean is on UniFi Network 10.6.106 running a UCG Fiber. The generic
"UniFi Network terminology" firewall/DNAT guidance in `docs/operations.md`
was replaced with steps specific to that version and hardware, based on web
research done in this session: Ubiquiti's own UCG Fiber tech-spec page and
the UniFi Network 10.6.97 community release notes confirm the UCG Fiber
supports Network 10.6 with the full zone-based firewall and Policy Engine
(some older forum threads describe a cut-down feature set on earlier
UCG-Fiber firmware tied to network application 8.x; that does not apply to
Sean's current 10.6.106).

Ubiquiti's own help-center pages (`help.ui.com`) returned HTTP 403 to this
session's automated fetch tool and could not be read directly; the exact
Policy Engine field labels (Type, NAT Type, Source, Destination, Translated
IP/Port) documented in `docs/operations.md` are cross-checked from a
third-party walkthrough (a GitHub Gist documenting the same DNAT-for-DNS
pattern against UniFi Network 9.4.17) plus Ubiquiti's tech-spec and release-
notes pages, not a first-party screenshot of the 10.6 UI. This is stated
explicitly rather than presented as directly verified: if a field name in
the live UI differs, the underlying rule shape (Destination NAT with
Source = VLAN, Destination = Any, Translated IP/Port = this app) is what
matters and should be preserved even if the exact label differs.

The recommendation to redirect (DNAT) plain DNS (port 53) rather than block
it, while blocking rather than redirecting DoT (853) and DoH/DoQ (443), is
based on a TLS property (certificate hostname/CA validation), not a UniFi
limitation: DNAT is invisible to a plain-DNS client since it never
validates who answered, but a DoT/DoH client's TLS handshake validates the
resolver's identity, so silently redirecting it to a different server's
certificate causes a hard validation failure rather than a working
connection. See `docs/operations.md`, "Why DoT/DoH cannot be silently
redirected like plain DNS", for the full explanation.

Whether the UCG Fiber's advertised "application-aware layer 7 firewall" and
"DPI & traffic identification" features can specifically fingerprint and
block DoH-over-TCP-443 (the one gap a Layer 4 firewall rule cannot close,
since DoH shares its port with all other HTTPS traffic) was not checked
against a live UCG Fiber Settings screen in this session; this is flagged
as something to check in the Policy Engine directly rather than assumed
either way.

## UniFi local-hostname resolution preserved via a Conditional Forwarder Zone (2026-09-15)

Sean pointed out that DHCP leases in his environment are issued by the
UniFi controller (a UCG Fiber), not this app, and asked whether an
equivalent zone-forwarding setup was needed on the UniFi side. Researched
rather than assumed: Ubiquiti's own documentation and community sources
confirm the UniFi gateway runs a genuine internal DNS forwarder (not
mDNS/Bonjour) that answers hostname lookups for its own DHCP clients,
qualified under a per-network Domain Name (Settings > Networks > Advanced,
default `.localdomain` if never set -- deliberately not `.local`, which
collides with Apple's Bonjour resolution). That resolution only works for a
client actually querying the gateway; redirecting client DNS to this app
(via DHCP Name Server or the DNAT/firewall rules documented above) would
silently break it, since this app has never heard of those hostnames.

Documented the fix as a Conditional Forwarder Zone in Technitium pointed at
the UniFi gateway's own LAN address for that network's Domain Name --
the same pattern already used for the internal Windows AD domain, applied
to a different upstream. See docs/operations.md, "Local UniFi hostname
resolution: a Conditional Forwarder Zone back to the gateway".

One piece of this is explicitly flagged as unverified rather than assumed
solved: whether the UniFi gateway's internal forwarder answers a query
arriving from another DNS server acting as a forwarding client (as
Technitium would, in this role) the same way it answers a query from an
ordinary LAN client device. The sources found describe the client-facing
case only. docs/operations.md gives a specific lookup to run to confirm
this before relying on it, and a fallback (keep a specific VLAN's DHCP Name
Server on Auto) if it turns out not to work as expected.

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
