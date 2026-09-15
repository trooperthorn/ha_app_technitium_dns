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
