# Operations

## Automated upstream sync

`sync-upstream.yml` runs daily (09:23 UTC) and on manual dispatch, checking
Docker Hub for a newer stable `technitium/dns-server` tag or a re-published
digest on the current tag. When something moved, `scripts/sync_upstream.py`
rewrites the pin in `technitium_dns/Dockerfile` (the `FROM` line and its
header comment), and the workflow pushes `automation/upstream-sync` and opens
an auto-merging PR. If the tag itself moved, the PR body also flags a manual
review: whether the `.NET` runtime-overlay stage (see the Dockerfile's
"Runtime overlay to clear High CVEs" comment) is still needed against the new
Technitium image, since that judgment call is not automated. The chain after
merge: `release.yml` runs, `prepare-release.yml` bumps CalVer on
`technitium_dns/config.yaml`, that PR merges, and Home Assistant offers the
new version.

Like `prepare-release.yml`, this workflow mints a short-lived token from the
release GitHub App: repository variable `RELEASE_AUTOMATION_CLIENT_ID` and
secret `RELEASE_AUTOMATION_PRIVATE_KEY`. **Neither is configured on this
repository yet** (`gh variable list` / `gh secret list` both return nothing as
of 2026-09-22) -- the App must be installed here (see
`~/.claude/skills/ha-dev-current` inventory notes on the other repos it is
already installed on for the install/verify steps) before this workflow can
open PRs; until then it fails at the "Verify release-automation credentials
are configured" step whenever it detects a change, without touching the repo.

Manual check or apply, without waiting for the schedule:

```bash
python scripts/sync_upstream.py --check   # report only
python scripts/sync_upstream.py           # apply, then commit on a branch
```

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

## Example: Quad9 global forwarder with an internal AD conditional zone

This is a worked example for a specific mixed setup: most traffic is
internet lookups, one internal Windows AD domain lives on a separate DNS
server, and Quad9 is the desired upstream for everything else. It is
configured entirely in Technitium's own web console after first start (see
"Option changes after first boot do not apply" above), not through this
app's `forwarders`/`forwarder_protocol` options, since a live install
already has a persisted configuration.

1. Settings > DNS (Forwarders section):
   - **Forwarders**: `9.9.9.9`, `149.112.112.112` (Quad9's two anycast
     addresses; add `2620:fe::fe` and `2620:fe::9` as well if this server
     also serves IPv6 queries).
   - **Forwarder Protocol**: `Tls`. Quad9 supports DNS-over-TLS on port 853;
     setting this makes this server's own upstream queries encrypted, not
     only the client-to-this-server leg. Confirm Quad9's current DoT
     hostname/certificate details against their own documentation before
     relying on this if Quad9 changes their DoT endpoint in the future --
     not re-verified beyond what was true when this was written.
   - This makes Quad9 the effective upstream for every query this server
     does not answer authoritatively and does not match a more specific
     zone below. It is a forwarder relationship, not root-hints recursion:
     Technitium is not walking the DNS root hierarchy itself here.
2. Zones > Add Zone, twice, for the internal AD domain:
   - **Zone Type**: Conditional Forwarder, **Zone Name**: the real AD domain
     name (e.g. `lab.local`), **Forwarder**: the internal Windows DNS
     server's address, **Protocol**: `Udp` (an internal server on the same
     LAN does not need the TLS overhead relevant to an internet-facing
     forwarder like Quad9 above).
   - **Zone Type**: Conditional Forwarder, **Zone Name**: the reverse zone
     covering the AD network's address range (e.g. `10.in-addr.arpa` for a
     `10.0.0.0/8` internal range), **Forwarder**: the same internal Windows
     DNS server, **Protocol**: `Udp`. Without this, PTR lookups against the
     internal range would go to Quad9 instead, which has never heard of
     that range and would return nothing.
3. Verify from a client on the internal network: `nslookup
   <known-internal-hostname>` pointed at this app's address should return
   the AD answer via the conditional zone, and `nslookup <any-internet-
   hostname>` should return an answer via Quad9. Conditional-zone precedence
   over the global Forwarders list is Technitium's documented behavior but
   was not independently re-verified against a live query for this specific
   example; run this check before trusting it in production.

This does not change anything in `technitium_dns/config.yaml` -- the
`forwarders`/`forwarder_protocol` options there remain first-run-only
defaults for a fresh install, and the Conditional Forwarder Zone feature has
no equivalent option in this app at all (see
`technitium_dns/translations/en.yaml`, "forwarders"/"forwarder_protocol"
descriptions, for the same guidance aimed at someone configuring first
start instead of an already-running instance).

## Local UniFi hostname resolution: a Conditional Forwarder Zone back to the gateway

Sean's DHCP leases are issued by the UniFi controller/gateway (a UCG Fiber),
separately from this app. Pointing DHCP's Name Server option at this app (or
redirecting client DNS to it via the firewall rules below) is still correct
and does not depend on who issues DHCP leases -- but it has one consequence
worth handling deliberately: UniFi's gateway maintains its own internal DNS
forwarder that answers local hostname lookups for DHCP clients (confirmed
via Ubiquiti's own documentation and community sources, read 2026-09-15:
when a client's DHCP negotiation includes its hostname, the gateway pushes
it into that internal forwarder, qualified under a per-network domain name
configurable at Settings > Networks > (edit network) > Advanced > Domain
Name; if never set, UniFi defaults it to `.localdomain`, deliberately not
`.local`, since `.local` collides with Apple's Bonjour/mDNS resolution on
Apple devices -- this is genuine unicast DNS the gateway answers, not
mDNS). That resolution only works for a client actually querying the
gateway; once a client's DNS traffic goes to this app instead (via DHCP
Name Server or the DNAT rule below), it stops being able to resolve other
local device hostnames, since this app has never heard of them.

The fix is the same Conditional Forwarder Zone pattern used for the
internal Windows AD domain (see "Example: Quad9 global forwarder with an
internal AD conditional zone" above), pointed at the UniFi gateway instead:

1. Check each VLAN's actual Domain Name value at Settings > Networks >
   (that network) > Advanced > Domain Name in the UniFi controller --
   confirm it rather than assuming the `.localdomain` default, since UniFi
   allows a different domain per network and Sean may have set one
   explicitly.
2. In Technitium's console, Zones > Add Zone, once per distinct domain in
   use:
   - **Zone Type**: Conditional Forwarder
   - **Zone Name**: that network's Domain Name value (e.g. `localdomain`)
   - **Forwarder**: the UniFi gateway's own LAN address on that network
   - **Protocol**: `Udp`
3. Verify using Technitium's own DNS Client/lookup tool in its console:
   query `<a-known-device-hostname>.<domain>` and confirm it resolves via
   the gateway rather than returning NXDOMAIN.

What step 3 specifically checks and what is not yet confirmed: Ubiquiti's
own documentation describes this local-hostname resolution from the
perspective of a LAN client querying the gateway directly. Whether the
gateway's internal DNS forwarder also answers a query arriving from another
DNS server acting as a forwarding client (Technitium querying it the same
way it queries the AD server or Quad9) rather than from an end-user device
was not confirmed against a source describing that server-to-server case
specifically. It should work, since Technitium's query still originates
from an ordinary LAN address the same as any other client, but this has not
been verified against a live gateway in this session -- run the lookup in
step 3 before relying on it, and if it returns NXDOMAIN where a direct
client query to the gateway would have succeeded, the gateway is likely
scoping answers in a way this conditional zone cannot work around, and
local hostname resolution for redirected clients would need a different
approach (such as keeping a specific trusted VLAN's DHCP Name Server on
`Auto` instead of pointing it at this app).

## Forcing all client DNS through this server (firewall/gateway rules)

Technitium cannot stop a device from ignoring the DNS server it was handed
by DHCP and querying a public resolver directly, over plain DNS, DoT, or
DoH/DoQ. That enforcement has to happen at the LAN firewall/gateway, not in
this app. Without it, a device that hardcodes `8.8.8.8` or auto-upgrades to
a public DoH resolver bypasses every setting in this app entirely,
including blocking, logging, and the Quad9/AD forwarding split above.

The steps below are written for **UniFi Network 10.6 on a UCG Fiber**
(Sean's gateway, confirmed on Network 10.6.106; Ubiquiti's own tech-spec
page confirms the UCG Fiber supports Network 10.6.97+ with the full
zone-based firewall and Policy Engine, not a cut-down feature set some
older UCG-Fiber firmware threads describe). In Network 10.6, Firewall
Rules, NAT rules (including Destination NAT), and Port Forwarding are all
policy *types* created from one place: **Settings > Policy Engine > Policy
Table > Create New Policy**, evaluated in the table's listed order top to
bottom -- there is no longer a separate "Port Forwarding" or "NAT" top-level
page the way older UniFi OS versions had them. The exact on-screen field
labels were cross-checked against a third-party walkthrough and Ubiquiti's
own UCG Fiber tech specs and 10.6.97 release notes rather than a direct
screenshot of Ubiquiti's help center (its help-center pages returned HTTP
403 to automated fetches in this session); if a label in the live UI
differs slightly, the underlying rule shape below (Destination NAT,
source = VLAN, destination = Any, translated IP/port) is what to preserve.

1. DHCP on every VLAN that should use this server must hand out this app's
   address as the only DNS server (DHCP Option 6). This is what makes
   well-behaved devices use it in the first place; the rules below are the
   backstop for the ones that do not.
2. **Plain DNS (port 53): redirect, don't just block.** Settings > Policy
   Engine > Policy Table > Create New Policy:
   - **Type**: `NAT`
   - **NAT Type**: `Destination NAT`
   - **Name**: e.g. `Redirect-DNS-to-Technitium`
   - **Source**: the VLAN's network (IoT, tablets/phones) -- not the trusted
     admin VLAN, unless that should be redirected too.
   - **Destination**: `Any` -- deliberately not a specific public resolver
     IP, so every hardcoded resolver (`8.8.8.8`, `9.9.9.9`, `1.1.1.1`, etc.)
     is caught, not just the ones you thought to list.
   - **Destination Port**: `53`
   - **Protocol**: this UI takes one protocol per rule; create the rule
     twice, once for `UDP` and once for `TCP`.
   - **Translated IP**: this app's LAN address. **Translated Port**: `53`.
   - Place both rules above the VLAN's general internet-access allow rule
     in the Policy Table's ordering, so they are matched first.

   This redirects transparently rather than just blocking: the device gets
   a working resolver (this one) instead of failed lookups, and every query
   -- including ones aimed at a hardcoded public IP -- now goes through this
   app's blocking/logging/Quad9-or-AD-forwarding configuration.
3. **DoT (853) and DoH/DoQ (443): block, do not attempt to redirect.**
   DNAT-redirecting an encrypted DNS connection to a server other than the
   one the client thinks it is validating breaks it rather than
   transparently rerouting it -- see "Why DoT/DoH cannot be silently
   redirected like plain DNS" below. Same Policy Table, **Type**: `Firewall
   Rule` this time, not NAT:
   - Optional, if enabling DoT on this app per step 4: **Action**: `Allow`,
     **Source**: the VLAN, **Destination**: this app's LAN address, **Port**:
     `853`/TCP -- placed above the block rule below so the specific allow is
     matched first.
   - **Action**: `Block`, **Source**: the VLAN, **Destination**: `Any`,
     **Destination Port**: `853`, **Protocol**: `TCP`.
   - **Action**: `Block`, **Source**: the VLAN, **Destination**: `Any`,
     **Destination Port**: `443`, **Protocol**: `UDP` (DoQ and most
     QUIC-based DoH).
   - TCP/443 (ordinary HTTPS) **cannot** be blocked wholesale -- DoH rides
     the same port as all other HTTPS traffic, and a Layer 4 firewall rule
     cannot tell them apart. This leaves a real gap: a device doing
     DoH-over-TCP-443 to a public resolver is indistinguishable from
     ordinary HTTPS browsing at this rule layer. The UCG Fiber's own spec
     sheet lists "application-aware layer 7 firewall" and "DPI & traffic
     identification" as supported features; whether either exposes a
     category that specifically fingerprints known public DoH endpoints by
     TLS SNI or certificate was not checked against a live UCG Fiber
     Settings screen in this session -- check Settings > Policy Engine for
     an application/traffic-identification rule type before assuming the
     Layer 4 rules above are the ceiling of what this gateway can do here.
4. Once DoT is enabled on this app with a certificate phones/tablets will
   actually trust (see "Getting a certificate for DoT/DoH so client
   validation succeeds" below), point each device's Private DNS / Automatic
   DoT setting at this server's hostname so it has a legitimate, working
   encrypted path here; the block rules in step 3 then stop it from reaching
   any other DoT/DoH endpoint.

**Verify, don't assume, once configured**: from a device on the redirected
VLAN, `nslookup example.com 8.8.8.8` should still return an answer (proving
the DNAT rule caught it) and that query should appear in Technitium's own
query log or this app's nginx access log, not reach Google at all. The
Policy Table shows a per-rule match/hit counter in Network 10.6 -- check it
to confirm the DNAT and block rules are actually being matched, not
silently skipped by rule ordering, before relying on any of this.

### Why DoT/DoH cannot be silently redirected like plain DNS

Plain DNS (port 53) has no transport security, so a DNAT rule works
invisibly: the device sends an unencrypted query to what it thinks is
`8.8.8.8`, the gateway rewrites the destination, and this app answers --
the device never validates who answered. DoT and DoH add TLS on top
specifically so the device *can* verify it is talking to the resolver it
intended: as part of the TLS handshake the device checks the presented
certificate's subject name against the hostname/IP it expects (e.g.
`dns.google` for Google's DoT/DoH, `dns.quad9.net` for Quad9) and against a
certificate authority it already trusts. A DNAT rule that transparently
swaps the destination to this app does not swap the certificate the client
receives -- Technitium still presents its own certificate for its own
hostname -- so the handshake fails certificate validation and the
connection is rejected outright. Most current mobile/desktop DoT/DoH clients
treat that as a hard failure, not a silent fall-back to plain DNS, so
attempting this redirect is more likely to break the device's connectivity
than to protect it. This is a property of TLS certificate validation, not a
gap in UniFi's NAT feature.

### Getting a certificate for DoT/DoH so client validation succeeds

The only way to make DoT/DoH to this server pass client-side validation
(rather than being blocked and forcing plain-DNS fallback) is to give
Technitium a certificate that is (a) issued by a CA the client already
trusts and (b) issued for a hostname the client is actually told to expect
-- self-signed certificates only work for a client explicitly configured to
trust that one certificate, which does not scale across a mixed phone/
tablet/IoT household the way Private DNS by hostname is meant to.

Practical path, if this is worth doing for your setup:

1. You need a domain name you control that can carry a public DNS record
   pointing at this server (e.g. a subdomain of a domain you already own,
   such as `dns.yourdomain.com`), even though the server itself only serves
   your LAN -- the certificate's validity does not require the name to be
   publicly reachable over DNS resolution traffic, only that a public CA can
   verify you control that name.
2. Use the **DNS-01** ACME challenge type (not HTTP-01) with a public CA
   such as Let's Encrypt, since HTTP-01 would require the CA to reach this
   server over the internet on port 80, which it should not be exposed to.
   DNS-01 only requires you to create a short-lived TXT record at your DNS
   provider proving control of the domain; it works for a purely
   internal/LAN-only server. This needs an ACME client that supports your
   DNS provider's API for the DNS-01 challenge (e.g. `certbot` with a
   provider-specific DNS plugin, or `acme.sh`) -- Technitium itself does not
   run an ACME client on your behalf; the certificate has to be obtained
   externally and imported into Technitium's own console (Settings >
   Optional Protocols, per "Enabling encrypted DNS for clients" above).
3. Set up renewal: Let's Encrypt certificates are valid 90 days, so this
   needs to be a recurring process (a scheduled task running the ACME
   client's renew command, then re-importing the renewed certificate into
   Technitium), not a one-time step -- Technitium does not automate this
   renewal internally, since it did not obtain the certificate itself.
4. Point each device's Private DNS setting at the exact hostname the
   certificate was issued for (e.g. `dns.yourdomain.com`), not this
   server's bare IP address -- DoT/DoH hostname validation is name-based,
   and pointing a device at a raw IP either fails validation outright or
   (depending on the OS) skips using the encrypted path entirely.

This is more operational overhead than most households take on for an
internal-only resolver, and was not set up or verified against a live
certificate in this session -- it is presented as the sound path if you
decide DoT for phones/tablets is worth the recurring renewal work, not as
something already done here. If it is not worth that overhead, the block
rules in step 3 above (forcing fallback to plain DNS, then caught by the
DNAT redirect in step 2) achieve most of the same practical outcome --
every client resolves through this server -- without needing a public CA
relationship at all.

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
