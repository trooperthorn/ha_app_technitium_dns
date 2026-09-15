# Operations

## Retrieving the first-run admin password

If the `admin_password` option was left blank, `run.sh` generates a random
24-character password on the app's first start and logs it exactly once, as
a line reading `Initial Technitium admin password: <password>`. Check the
app's log immediately after the first install and start; the password is
not logged again on later restarts. It is also saved to
`/data/admin_password` inside this app's own data directory (mode 600) if
it needs to be recovered without scrolling back through logs; that file is
included in a Home Assistant backup of this app's data the same as any
other file under `/data`.

If both the log and the file are lost, and the admin account's password
cannot be reset through Technitium's own web console (Technitium supports
this from a logged-in admin session, but not from a fully logged-out
state), the only remaining path is the destructive config wipe described
below, followed by a fresh first start.

## Option changes after first boot do not apply

Every option in `technitium_dns/config.yaml` maps to an upstream
`DNS_SERVER_*` environment variable that Technitium reads only when no
configuration file exists yet at `/etc/dns/dns.config` (mapped to
`/data/etc-dns/dns.config` by this app). Once that file exists, Technitium
owns its own configuration; editing an option in this app's UI and
restarting has no effect.

To change a setting after first boot:

1. Preferred: change it directly in Technitium's own web console (reached
   through the Ingress panel). This is the supported path for every setting
   this app's options originally seeded.
2. Destructive alternative: delete the persisted configuration under
   `/data/etc-dns` and restart the app so it goes through first start again
   with the current options. This also deletes zones and any other
   configuration made through Technitium's own console since first start,
   not just the options this app manages. Take a Home Assistant backup of
   this app's data first if anything in it matters.

This app does not build an automatic "wipe and reseed" toggle for option
changes; see docs/decisions.md for why.

## Port 53 conflicts

Mapping `53/tcp` and `53/udp` to the host means this app cannot start if
another process already holds those ports on the host you map them to
(commonly `systemd-resolved` on a Linux host acting as the Supervisor host,
or another DNS server app). If the app fails to start with a port-bind
error, check what already holds port 53 on that host before assuming a bug
in this app. The host-side port in `ports:` can be changed to something
other than 53 in the app's Network configuration screen if a conflict on 53
itself cannot be resolved, though LAN clients would then need to be pointed
at that alternate port explicitly.

## Backup and restore of `/data`

Technitium's entire live state, configuration, zones, and logs live under
`/data` (`/data/etc-dns` and `/data/log/technitium/dns`). Home Assistant's
Backups feature includes this app's `/data` directory automatically as part
of a full or partial backup that includes this app; there is no separate
export/import step. Restoring a backup restores Technitium to exactly the
state it was in when the backup was taken, admin password and zones
included.

## HEALTHCHECK limitation

The Dockerfile's `HEALTHCHECK` only confirms the web console's HTTP port
(5380) accepts a connection. It does not exercise DNS resolution on port
53 at all, so a `healthy` container status does not by itself confirm LAN
clients can actually resolve names through this app. If DNS resolution
appears broken while the app itself reports healthy, check the app log and
Technitium's own web console before assuming the container is fine.
