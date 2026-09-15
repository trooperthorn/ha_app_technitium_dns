# Changelog

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
