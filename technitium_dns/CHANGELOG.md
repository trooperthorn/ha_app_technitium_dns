# Changelog

## Unreleased
- Documentation only, no image/config change: added a worked example for a
  Quad9 global forwarder plus a Conditional Forwarder Zone to an internal
  Windows AD DNS server, and firewall/gateway guidance for forcing client
  DNS through this app. See docs/operations.md and docs/decisions.md.
- Documentation only: replaced the generic firewall/DNAT guidance with
  verified, UCG Fiber-specific UniFi Network 10.6 Policy Engine steps
  (Destination NAT for port 53, Firewall Rules for blocking 853/443), plus
  a certificate-acquisition path for DoT/DoH if that's ever pursued. See
  docs/operations.md and docs/decisions.md.
- Documentation only: added a Conditional Forwarder Zone pattern for
  preserving UniFi's own local-hostname DNS resolution once client DNS is
  redirected to this app. See docs/operations.md and docs/decisions.md.

## 2026.09.15.8
- Switched the Ingress reverse proxy to `nginx-light` (confirmed to include
  every module this config uses, smaller footprint than the full `nginx`
  package). Considered lighttpd, Caddy, and HAProxy instead; kept nginx.
  See docs/decisions.md.
- Added a web console access log for SOC audit tracking: one JSON line per
  Ingress request at `/data/log/nginx/web_console_access.log`, including
  the authenticated Home Assistant user identity (not just an IP, which is
  always the Ingress gateway's own address). New
  `web_console_access_log_retention_days` option (default 90), applied on
  every start. Rotated daily via a background `logrotate` loop (no cron
  daemon in this container). See docs/operations.md.
- Filled in missing `network:` translations for the 853/443 ports (present
  in `config.yaml` since 2026.09.15.3 but missing from
  `translations/en.yaml`).

## 2026.09.15.7
- Fixed the Ingress panel showing "refused to connect": Technitium's own
  web console sends `X-Frame-Options: DENY` and a CSP with
  `frame-ancestors 'none'`, which block Home Assistant Ingress from
  embedding it in an iframe at all. Added an nginx reverse proxy
  (`technitium_dns/nginx.conf`) in front of the web console (only the web
  console; DNS traffic is unaffected) that replaces those headers with
  same-origin-only framing. Technitium now listens on loopback-only 5381
  instead of 5380. See docs/decisions.md.
- **If you installed a version before this one**, see docs/operations.md,
  "If you installed before 2026.09.15.7: reset the persisted config once",
  before updating -- the old persisted configuration conflicts with this
  version's port layout.

## 2026.09.15.6
- Enforced `technitium_dns/apparmor.txt` (removed the `complain` flag) at
  Sean's explicit direction. This has not been verified against a live
  Home Assistant Supervisor install; see docs/decisions.md, "AppArmor:
  enforced without live verification", and docs/operations.md for what to
  check if the app fails to start or initialize after this change.

## 2026.09.15.5
- Added a runtime smoke-test job to the Test workflow: builds the image,
  runs it against a Supervisor-shaped `/data`, waits for the container's own
  HEALTHCHECK to report healthy, confirms the `.NET` runtime overlay
  actually landed (10.0.12 present, 10.0.9 gone), and confirms a plain DNS
  query resolves through the mapped port. Previously CI only confirmed the
  image builds, not that it starts or serves.

## 2026.09.15.4
- Fixed the Security workflow's vulnerability scan failure (six High-severity
  GHSA advisories against .NET runtime 10.0.9, bundled in Technitium's own
  newest release). Overlays `mcr.microsoft.com/dotnet/aspnet:10.0.12`'s
  shared frameworks onto the Technitium image and removes the old 10.0.9
  version folders. See docs/decisions.md, "Runtime overlay to clear High
  CVEs".

## 2026.09.15.3
- Exposed the standard ports for DNS-over-TLS (853/tcp), DNS-over-HTTPS
  (443/tcp), and DNS-over-QUIC (443/udp), mapped off (`host: null`) by
  default. Documented the full client-facing port table and the one-time
  in-app steps to enable each protocol with a certificate in Technitium's
  own web console. See docs/decisions.md and docs/operations.md.

## 2026.09.15.2
- Fixed `run.sh` calling `bashio`, which is not present in this image (this
  app builds `FROM technitium/dns-server`, not a Home Assistant base image);
  the container would have failed to start. `run.sh` now reads
  `/data/options.json` directly with `jq`. See docs/decisions.md, "Security
  audit findings and fixes".
- Added a custom `technitium_dns/apparmor.txt` profile, shipped in
  `complain` mode pending live verification. See docs/decisions.md, "Custom
  AppArmor profile, shipped in complain mode", and docs/operations.md,
  "Verifying and enforcing the AppArmor profile".

## 2026.09.15.1
- Initial release. Fresh Dockerfile built from `technitium/dns-server:15.4.0`,
  Home Assistant Ingress for the web console, explicit `53/tcp` and `53/udp`
  host port mapping, first-run admin password generated to a file instead of
  a fixed default, `stage: experimental` pending field use. See
  docs/decisions.md for the design choices and docs/security.md for what is
  and is not verified about the upstream image.
