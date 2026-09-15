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
