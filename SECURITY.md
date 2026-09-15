# Security Policy

## Reporting a vulnerability

Do not open a public issue containing exploit details, credentials, private
addresses, or logs. Use GitHub's private vulnerability-reporting feature for
this repository. If private reporting is unavailable, open a minimal issue
asking the maintainer to establish a private channel; omit technical details.

Include the affected version/commit, prerequisites, impact, a minimal
reproduction, and suggested remediation. Remove tokens, passwords, and
private network details.

## Response targets

These are project targets, not an SLA: acknowledge critical/high reports in
three business days, establish severity and containment in seven, and publish
a coordinated fix/advisory as soon as safely validated. Lower-severity issues
are prioritized by exploitability and impact.

## Supported version

Only the latest published release and the default branch receive security
fixes. Operators should keep Home Assistant, this app, and the upstream
Technitium image current, and retain a tested backup of the app's data
directory (see docs/operations.md).

## Security boundaries

This app bridges DNS resolution for the entire local network: every device
that points at it depends on it to resolve names, and a failure or
compromise here is a network-wide outage or a network-wide DNS integrity
problem, not a single-app issue. Its boundaries, as actually configured:

- The web console is reachable only through Home Assistant's authenticated
  Ingress panel. It is never exposed on a host port; see docs/decisions.md.
- `host_network` is not used. Only port 53 (tcp and udp) is mapped to the
  host, which is the minimum this app's stated purpose (LAN DNS resolution)
  requires; see docs/decisions.md for the security-rating math behind that
  choice.
- The container image is built from the upstream `technitium/dns-server`
  image at a pinned tag and digest (see `technitium_dns/Dockerfile`). This
  app trusts that image's supply chain and does not re-audit Technitium's
  own source; a vulnerability in Technitium itself or in its base .NET
  runtime image is outside this app's control.
- Whether the upstream image drops root privileges is unverified; the
  process is confirmed to run as root by default because upstream ships no
  `USER` directive, and this app does not add one. See docs/security.md,
  "Container user: unverified / not changed".
- Once Technitium has written its own configuration on first start, later
  changes to this app's options do not apply; the Technitium web console
  becomes the source of truth. See `technitium_dns/DOCS.md`.
