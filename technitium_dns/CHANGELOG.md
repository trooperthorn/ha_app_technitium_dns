# Changelog

## 2026.09.15.1
- Initial release. Fresh Dockerfile built from `technitium/dns-server:15.4.0`,
  Home Assistant Ingress for the web console, explicit `53/tcp` and `53/udp`
  host port mapping, first-run admin password generated to a file instead of
  a fixed default, `stage: experimental` pending field use. See
  docs/decisions.md for the design choices and docs/security.md for what is
  and is not verified about the upstream image.
