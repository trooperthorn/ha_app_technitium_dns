# Technitium DNS Server

A packaging of [Technitium DNS Server](https://technitium.com/dns/) as a Home
Assistant app. Technitium is a full-featured authoritative and recursive DNS
server with ad/tracker blocking, DNS-over-HTTPS/TLS/QUIC forwarding, and its
own web-based admin console.

This app runs Technitium as your household's DNS resolver. Read
docs/decisions.md and docs/operations.md in the repository before deploying
it as the only resolver on your network; several behaviors here differ from
a typical Home Assistant app because DNS is infrastructure, not a dashboard.

## First start

1. Add and start the app. Check the app log for a line reading
   `Initial Technitium admin password: ...`. It is logged exactly once,
   during the first start when no configuration exists yet. Record it before
   the log scrolls past it. See docs/operations.md for how to retrieve it
   again if you miss it.
2. Open the Technitium web console from the Home Assistant sidebar (Ingress).
   Log in as `admin` with the password from step 1.
3. From this point forward, use Technitium's own web console to manage
   zones, forwarders, blocking, and every other setting. See "Options only
   apply on first start" below.

## Options only apply on first start

Technitium's Docker image reads the `DNS_SERVER_*` environment variables
this app sets from its options **only when no configuration file exists
yet**. After the first successful start, Technitium writes its own
configuration under this app's persistent data directory, and that file
becomes the source of truth. Changing an option in this app's configuration
screen after that point has no effect until you either:

- change the equivalent setting in Technitium's own web console, or
- delete the app's persisted configuration to force Technitium to reseed
  from options on the next start (destructive: this discards every zone,
  forwarder, and blocking setting you configured through the web console;
  see docs/operations.md).

This app does not offer an automatic "wipe and reseed" toggle. That is a
deliberate choice, not an oversight: an option flip that silently deletes a
running DNS configuration is worse than requiring a manual, documented step.

## Network role

This app is meant to be the DNS resolver LAN clients point at. It maps port
`53/tcp` and `53/udp` to the host (default host port `53`) instead of using
`host_network: true`. If something else on your Home Assistant host already
binds UDP/TCP port 53 (a local DNS resolver, another app, systemd-resolved
listening on the same interface), the container will fail to start until
that conflict is resolved. See docs/operations.md.

## Web console access

The Technitium web console is reachable only through the Home Assistant
Ingress panel (the sidebar entry this app adds). It is not exposed on any
host port. See docs/security.md and docs/decisions.md for why.
