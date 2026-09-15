# Technitium DNS Server for Home Assistant

A Home Assistant app repository packaging [Technitium DNS
Server](https://technitium.com/dns/) so it can be installed, started, and
supervised from Home Assistant OS or Supervised installations.

The app builds its own container image from the upstream
`technitium/dns-server` image (see `technitium_dns/Dockerfile` for the pinned
tag and digest), maps port 53 for DNS traffic, and exposes the Technitium web
console only through Home Assistant's authenticated Ingress panel.

## Adding this repository

In Home Assistant, go to Settings, then Add-ons (App store), then the
three-dot menu, then Repositories, and add:

```
https://github.com/trooperthorn/ha_app_technitium_dns
```

Then install "Technitium DNS Server" from the Local apps section.

## Documentation

- [technitium_dns/DOCS.md](technitium_dns/DOCS.md): app usage, first-run
  password retrieval, and the option-only-applies-once limitation.
- [docs/decisions.md](docs/decisions.md): why this app is built the way it
  is (Ingress-only web console, explicit port mapping instead of
  `host_network`, image base choice).
- [docs/security.md](docs/security.md): security rating, trust boundaries,
  and what is and is not verified about the upstream image.
- [docs/operations.md](docs/operations.md): first-run password retrieval,
  the option-change limitation, port 53 conflicts, and backup/restore.
- [SECURITY.md](SECURITY.md): vulnerability reporting for this repository.

## Status

`stage: experimental` (see `technitium_dns/config.yaml` and
`docs/decisions.md`). This app has not yet been run as a household resolver
in the field.
