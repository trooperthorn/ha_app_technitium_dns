# Changelog

## 2026.10.10.1
- Added an optional read-only monitoring API listener on container port
  `5382/tcp` (`host: null`, off by default) so Observe or another LAN
  monitor can poll Technitium's dashboard stats and update check without a
  Home Assistant Ingress session. nginx proxies exactly three paths
  (`/api/dashboard/stats/get`, `/api/user/checkForUpdate`,
  `/api/user/session/get`) to Technitium and answers 403 for everything
  else, including login, token creation, settings, zones, and the console
  pages. Technitium still authenticates every call with its own user token
  (`Authorization: Bearer <token>`, or the legacy `?token=` form). The
  listener is rate limited per source address, accepts only private source
  addresses, and logs to the same SOC access log with
  `"listener":"monitoring_api"`. The web console stays Ingress-only and is
  not served on this port. See docs/operations.md, "Monitoring API port for
  Observe or other tools", docs/security.md, and docs/decisions.md.
- The SOC access log gained a `listener` field (`ingress` or
  `monitoring_api`) on every line; Ingress lines are otherwise unchanged.
  Monitoring-listener lines log the LAN client address and redact any
  `token=` or `pass=` value in the query string.
- The CI smoke test now also runs `nginx -t` inside the started container,
  checks the Ingress listener still answers 200 with same-origin framing
  headers, and exercises the monitoring listener end to end: the 403 fence,
  a bad token reaching Technitium, a real token through the allow-list in
  both header and query form, the rate limit, and the log fields.
- Technitium DNS Server 15.5.1 -> 15.6.0 (automated upstream sync,
  2026-10-05). Review the runtime-overlay rationale comments in the
  Dockerfile ("Runtime overlay to clear High CVEs"): confirm whether
  technitium/dns-server:15.6.0 still bundles a vulnerable .NET runtime, and
  whether the overlay's own pinned aspnet patch version is still the newest
  available.
- dotnet/aspnet overlay stage digest refreshed by Dependabot (2026-10-08).

## 2026.09.23.1
- Added the automated upstream sync (`sync-upstream.yml` and
  `scripts/sync_upstream.py`): checks Docker Hub daily for a newer
  `technitium/dns-server` tag or digest and opens an auto-merging PR. See
  docs/operations.md, "Automated upstream sync".
- Technitium DNS Server 15.4.0 -> 15.5.0, then 15.5.0 -> 15.5.1 (Dependabot
  and the upstream sync). Review the runtime-overlay rationale comments in
  the Dockerfile ("Runtime overlay to clear High CVEs") against each new
  upstream image.
- dotnet/aspnet overlay stage digest refreshed by Dependabot.

## 2026.09.15.9
- Promoted `stage` from `experimental` to `stable`: Sean confirmed a real
  installation running this app as the household DNS resolver, resolving
  correctly. See docs/decisions.md. This does not itself upgrade the
  separately-stated verification status of the Ingress fix, SOC access
  logging, or AppArmor enforcement -- see their own entries.
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
