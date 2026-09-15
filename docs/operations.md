# Operations

## If you installed before 2026.09.15.7: reset the persisted config once

Versions before `2026.09.15.7` had Technitium listen directly on port 5380,
which Home Assistant Ingress could reach but could never actually display:
Technitium's web console sends framing-blocking headers that make the
browser refuse to embed it in Ingress's iframe (see docs/decisions.md,
"Ingress panel blocked by Technitium's own frame-blocking headers"). If you
installed and started this app before that version, Technitium already
persisted a configuration file with port 5380 baked in, which now conflicts
with `2026.09.15.7`'s nginx reverse proxy (also on 5380) -- the container
will not start cleanly on top of that old configuration.

Since a pre-`2026.09.15.7` install could never actually reach the web
console to configure anything real (that was the whole bug), the fix is the
same destructive reset described in "Option changes after first boot do not
apply" below, done once:

1. Stop the app.
2. Delete the persisted configuration: remove `/data/etc-dns` (and
   `/data/admin_password`, so a fresh one gets generated and logged again)
   from this app's data directory.
3. Update to `2026.09.15.7` or later and start the app. It goes through
   first start again, this time seeded with the nginx-fronted values, and
   generates a new admin password.

If you had already configured real zones or settings through Technitium's
console before hitting this (unlikely, since the console was unreachable),
back up `/data` first; this reset discards anything under `/data/etc-dns`.

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

## Enabling encrypted DNS for clients (DoT, DoH, DoQ)

This app maps the standard ports for DNS-over-TLS (853/tcp), DNS-over-HTTPS
(443/tcp), and DNS-over-QUIC (443/udp) in `technitium_dns/config.yaml`, but
leaves the host side of each set to `null` (not mapped) by default, and
mapping the port alone does not turn the protocol on: Technitium has no
first-run environment variable for any of the three (confirmed against
`DockerEnvironmentVariables.md` in the upstream repository, read
2026-09-15), unlike the plain-DNS and recursion/blocking/forwarder settings
this app's own options do seed. Enabling one is a one-time, in-app step:

1. In this app's Network configuration screen (Supervisor > this app >
   Network), set the host side of whichever of `853/tcp`, `443/tcp`, or
   `443/udp` you want to use to the same number (or leave it at the standard
   number unless something else on the host already holds it).
2. Log in to Technitium's own web console (via the Ingress panel).
3. Go to Settings > Optional Protocols (Technitium's own menu path; consult
   Technitium's documentation at https://technitium.com/dns/ if the exact
   location has moved in a version newer than what this app pins) and supply
   a TLS certificate for DoT/DoH/DoQ. This is a separate certificate from
   the one, if any, used for the web console's own HTTPS -- this app runs
   the web console over plain HTTP behind Ingress and does not configure
   one (see docs/decisions.md), so a certificate for encrypted DNS has to be
   supplied here regardless. A certificate from a public CA is required for
   phone and desktop OS resolvers to trust it without manual installation; a
   self-signed certificate works only for clients you configure to trust it
   explicitly.
4. Enable the specific protocol(s) you mapped a port for, and confirm from a
   client that supports it (most current iOS, Android, Windows, and browser
   DNS clients support DoT and/or DoH) that resolution actually works before
   relying on it.

Restart the app after step 1 for the port mapping change to take effect;
steps 2 to 4 take effect immediately in Technitium's own console without a
restart. If you stop using a protocol, set its host port back to `null` in
the Network configuration screen so it is not left reachable for nothing.

## Web console access log for SOC audit tracking

Every request through the Ingress-facing web console is logged as one JSON
line to `/data/log/nginx/web_console_access.log`, including the Home
Assistant user identity Ingress attaches after authenticating the viewer
(`user_id`, `user_name`, `user_display_name` fields, sourced from the
`X-Remote-User-*` headers Ingress adds), the request method and path,
response status, and timing. Example line shape:

```json
{"time":"2026-09-15T18:02:11+00:00","remote_addr":"172.30.32.2","user_id":"abc123","user_name":"homeadmin","user_display_name":"HomeAdmin","method":"GET","uri":"/","status":200,"body_bytes_sent":4021,"request_time":0.014,"user_agent":"Mozilla/5.0 ..."}
```

`remote_addr` is always the Ingress gateway's own address
(`172.30.32.2`), not the browser's -- every request nginx sees arrives from
there, so the `user_*` fields are the actual identifying information for
"who accessed this," not the IP.

Retention is controlled by the `web_console_access_log_retention_days`
option (default 90 days) and, unlike this app's other options, applies on
every start: change it and restart the app to take effect immediately, no
first-run reseed needed. Rotation runs once a day via a plain background
loop calling `logrotate` (this container has no cron daemon); rotated files
are compressed and dated (`web_console_access.log-20260915.gz` style) in
the same directory.

This file is not automatically wired into any specific SOC ingestion
pipeline -- see docs/decisions.md, "Web console access log for SOC audit
tracking", for what that would still require on the `ha_Int_soc` side.
Until that connection exists, review it directly (via a Home Assistant
backup, SSH to the host, or Supervisor's `docker exec` into this app's
container) rather than assuming it already appears anywhere in the SOC UI.

## Backup and restore of `/data`

Technitium's entire live state, configuration, zones, and logs live under
`/data` (`/data/etc-dns` and `/data/log/technitium/dns`). Home Assistant's
Backups feature includes this app's `/data` directory automatically as part
of a full or partial backup that includes this app; there is no separate
export/import step. Restoring a backup restores Technitium to exactly the
state it was in when the backup was taken, admin password and zones
included.

## AppArmor: enforcing without live verification, and how to recover

`technitium_dns/apparmor.txt` enforces as of 2026-09-15 (no `complain` flag),
at Sean's explicit direction, without ever having been checked against a
real Home Assistant Supervisor install. The CI smoke test that runs this
image (`.github/workflows/test.yml`) uses a plain `docker run`, which never
attaches this custom profile at all -- only Supervisor does that. So if
something this profile denies turns out to be something Technitium or
`run.sh` actually needs, the first real installation is where that would
surface, and it would surface as the container failing to start, failing
first-run initialization under `/data`, or failing to bind port 53 -- not as
a clear "AppArmor" error from Home Assistant's own UI.

If any of that happens after installing this app:

1. On the Home Assistant host, check for denials:
   `journalctl _TRANSPORT="audit" -g 'apparmor="DENIED"'`. Look for entries
   naming profile `technitium_dns`.
2. If there are denial entries, they name the exact capability or file
   operation that was blocked. Add the narrowest fix for that specific
   entry to `technitium_dns/apparmor.txt` (or reintroduce the `complain`
   flag on the profile's `flags=(...)` line as an immediate unblock while
   you work out the right fix), rebuild, and reinstall.
3. If there are no denial entries and the app still fails, the problem is
   not AppArmor; look at the container's own logs
   (Supervisor > this app > Log) before anything else.

This app does not claim the enforce-mode profile has been proven correct;
see docs/decisions.md, "AppArmor: enforced without live verification", and
docs/security.md for why file access mediation in this profile stays broad
regardless.

## HEALTHCHECK limitation

The Dockerfile's `HEALTHCHECK` only confirms the web console's HTTP port
(5380) accepts a connection. It does not exercise DNS resolution on port
53 at all, so a `healthy` container status does not by itself confirm LAN
clients can actually resolve names through this app. If DNS resolution
appears broken while the app itself reports healthy, check the app log and
Technitium's own web console before assuming the container is fine.
