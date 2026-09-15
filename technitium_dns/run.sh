#!/usr/bin/env bashio
# Reads Supervisor options from /data/options.json (via bashio::config),
# translates them into the environment variables Technitium's own container
# entrypoint reads on first start, then execs Technitium directly. See
# docs/operations.md for what happens on every start after the first, and
# docs/decisions.md for why this app does not try to change that.

set -o errexit -o pipefail

bashio::log.info "Starting Technitium DNS Server..."

CONFIG_DIR="/data/etc-dns"
LOG_DIR="/data/log/technitium/dns"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

FIRST_RUN=0
if [ ! -f "${CONFIG_DIR}/dns.config" ]; then
    FIRST_RUN=1
    bashio::log.info "No existing Technitium configuration found; this is a first run."
fi

# --- Admin password -------------------------------------------------------
# DNS_SERVER_ADMIN_PASSWORD and DNS_SERVER_ADMIN_PASSWORD_FILE are read only
# on first start when no config exists (see docs/security.md). A password
# typed into the app's own options screen would otherwise sit in Supervisor's
# plaintext /data/options.json for the life of the install with no way to
# rotate it from this app; generating a random password into a file under
# /data avoids shipping a fixed default and avoids that long-lived plaintext
# option value. If the operator did set admin_password anyway, honor it once
# so the honesty note in docs/security.md about that path stays accurate.
PASSWORD_FILE="/data/admin_password"
CONFIGURED_PASSWORD="$(bashio::config 'admin_password' '')"

if [ "$FIRST_RUN" -eq 1 ]; then
    if [ -n "$CONFIGURED_PASSWORD" ]; then
        printf '%s' "$CONFIGURED_PASSWORD" > "$PASSWORD_FILE"
        bashio::log.warning "admin_password option was set; using it for the initial admin account. Supervisor stores this option in plaintext at /data/options.json for the life of the install -- see docs/security.md."
    elif [ ! -f "$PASSWORD_FILE" ]; then
        GENERATED_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
        printf '%s' "$GENERATED_PASSWORD" > "$PASSWORD_FILE"
        bashio::log.info "Generated a random initial admin password and wrote it to /data/admin_password inside this app's own data directory (not shared with any other app)."
        bashio::log.info "Initial Technitium admin password: ${GENERATED_PASSWORD}"
        bashio::log.warning "Record this password now. It is logged only this once and is not recoverable from this app after the log line scrolls away; see docs/operations.md."
    fi
    chmod 600 "$PASSWORD_FILE"
else
    bashio::log.info "Existing configuration found; DNS_SERVER_* environment variables are ignored by Technitium after the first start. Change settings in the Technitium web console instead -- see docs/operations.md."
fi

export DNS_SERVER_ADMIN_PASSWORD_FILE="$PASSWORD_FILE"

# --- First-start-only options ---------------------------------------------
DOMAIN="$(bashio::config 'dns_server_domain' '')"
if [ -n "$DOMAIN" ]; then
    export DNS_SERVER_DOMAIN="$DOMAIN"
fi

export DNS_SERVER_PREFER_IPV6="$(bashio::config 'prefer_ipv6' 'false')"
export DNS_SERVER_RECURSION="$(bashio::config 'recursion' 'AllowOnlyForPrivateNetworks')"

RECURSION_ACL="$(bashio::config 'recursion_network_acl' '')"
if [ -n "$RECURSION_ACL" ]; then
    export DNS_SERVER_RECURSION_NETWORK_ACL="$RECURSION_ACL"
fi

export DNS_SERVER_ENABLE_BLOCKING="$(bashio::config 'enable_blocking' 'false')"

BLOCK_LIST_URLS="$(bashio::config 'block_list_urls' '')"
if [ -n "$BLOCK_LIST_URLS" ]; then
    export DNS_SERVER_BLOCK_LIST_URLS="$BLOCK_LIST_URLS"
fi

FORWARDERS="$(bashio::config 'forwarders' '')"
if [ -n "$FORWARDERS" ]; then
    export DNS_SERVER_FORWARDERS="$FORWARDERS"
    export DNS_SERVER_FORWARDER_PROTOCOL="$(bashio::config 'forwarder_protocol' 'Udp')"
fi

export DNS_SERVER_LOG_FOLDER_PATH="$LOG_DIR"
export DNS_SERVER_LOG_MAX_LOG_FILE_DAYS="$(bashio::config 'log_max_log_file_days' '7')"

# Ingress termination decisions (see docs/decisions.md): the web console
# listens on plain HTTP behind Ingress, which terminates TLS itself and
# authenticates the viewer before this app ever sees the request.
export DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS="false"
export DNS_SERVER_WEB_SERVICE_HTTP_PORT="5380"

# 172.30.32.2 is Home Assistant's documented Ingress gateway address
# (apps-cards-hacs.md section 1.12); without this, Technitium's own
# reverse-proxy trust check would reject every Ingress-forwarded request.
export DNS_SERVER_WEB_SERVICE_REVERSE_PROXY_ADDRESSES="172.30.32.2"

bashio::log.info "Handing off to Technitium DNS Server (config directory: ${CONFIG_DIR})."
exec /usr/bin/dotnet /opt/technitium/dns/DnsServerApp.dll "$CONFIG_DIR"
