#!/usr/bin/env bash
# Reads Supervisor options from /data/options.json directly with jq, not
# bashio: this image is FROM technitium/dns-server (Microsoft's dotnet/aspnet
# base), not a Home Assistant base image, so bashio -- an HA base-image-only
# shell library -- is not installed here. Translates the options into the
# environment variables Technitium's own entrypoint reads on first start,
# then execs Technitium directly. See docs/operations.md for what happens on
# every start after the first, and docs/decisions.md for why this app does
# not try to change that.

set -o errexit -o pipefail -o nounset

OPTIONS_FILE="/data/options.json"

log_info() {
    printf '[%s] INFO: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_warning() {
    printf '[%s] WARNING: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

# config_value <key> <default>: reads a top-level string/bool/number option
# from options.json. jq -r on a missing key yields the literal string "null",
# so that case is mapped back to the caller's default.
config_value() {
    local key="$1" default="$2" value
    value="$(jq -r --arg k "$key" '.[$k] // empty' "$OPTIONS_FILE" 2>/dev/null || true)"
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

log_info "Starting Technitium DNS Server..."

CONFIG_DIR="/data/etc-dns"
LOG_DIR="/data/log/technitium/dns"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

FIRST_RUN=0
if [ ! -f "${CONFIG_DIR}/dns.config" ]; then
    FIRST_RUN=1
    log_info "No existing Technitium configuration found; this is a first run."
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
CONFIGURED_PASSWORD="$(config_value 'admin_password' '')"

if [ "$FIRST_RUN" -eq 1 ]; then
    if [ -n "$CONFIGURED_PASSWORD" ]; then
        printf '%s' "$CONFIGURED_PASSWORD" > "$PASSWORD_FILE"
        log_warning "admin_password option was set; using it for the initial admin account. Supervisor stores this option in plaintext at /data/options.json for the life of the install -- see docs/security.md."
    elif [ ! -f "$PASSWORD_FILE" ]; then
        GENERATED_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
        printf '%s' "$GENERATED_PASSWORD" > "$PASSWORD_FILE"
        log_info "Generated a random initial admin password and wrote it to /data/admin_password inside this app's own data directory (not shared with any other app)."
        log_info "Initial Technitium admin password: ${GENERATED_PASSWORD}"
        log_warning "Record this password now. It is logged only this once and is not recoverable from this app after the log line scrolls away; see docs/operations.md."
    fi
    chmod 600 "$PASSWORD_FILE"
else
    log_info "Existing configuration found; DNS_SERVER_* environment variables are ignored by Technitium after the first start. Change settings in the Technitium web console instead -- see docs/operations.md."
fi

export DNS_SERVER_ADMIN_PASSWORD_FILE="$PASSWORD_FILE"

# --- First-start-only options ---------------------------------------------
DOMAIN="$(config_value 'dns_server_domain' '')"
if [ -n "$DOMAIN" ]; then
    export DNS_SERVER_DOMAIN="$DOMAIN"
fi

export DNS_SERVER_PREFER_IPV6="$(config_value 'prefer_ipv6' 'false')"
export DNS_SERVER_RECURSION="$(config_value 'recursion' 'AllowOnlyForPrivateNetworks')"

RECURSION_ACL="$(config_value 'recursion_network_acl' '')"
if [ -n "$RECURSION_ACL" ]; then
    export DNS_SERVER_RECURSION_NETWORK_ACL="$RECURSION_ACL"
fi

export DNS_SERVER_ENABLE_BLOCKING="$(config_value 'enable_blocking' 'false')"

BLOCK_LIST_URLS="$(config_value 'block_list_urls' '')"
if [ -n "$BLOCK_LIST_URLS" ]; then
    export DNS_SERVER_BLOCK_LIST_URLS="$BLOCK_LIST_URLS"
fi

FORWARDERS="$(config_value 'forwarders' '')"
if [ -n "$FORWARDERS" ]; then
    export DNS_SERVER_FORWARDERS="$FORWARDERS"
    export DNS_SERVER_FORWARDER_PROTOCOL="$(config_value 'forwarder_protocol' 'Udp')"
fi

export DNS_SERVER_LOG_FOLDER_PATH="$LOG_DIR"
export DNS_SERVER_LOG_MAX_LOG_FILE_DAYS="$(config_value 'log_max_log_file_days' '7')"

# Ingress termination decisions (see docs/decisions.md): the web console
# listens on plain HTTP behind Ingress, which terminates TLS itself and
# authenticates the viewer before this app ever sees the request.
#
# Technitium listens on 5381, loopback only, not port 5380: nginx (started
# below) owns 5380, the port this app's config.yaml declares as
# `ingress_port`, and proxies to Technitium on 5381. This exists because
# Technitium's own web console sends X-Frame-Options: DENY and a CSP with
# frame-ancestors 'none', which stop Home Assistant Ingress from embedding
# it in its iframe at all -- confirmed against a live install on 2026-09-15;
# see docs/decisions.md, "Ingress panel blocked by Technitium's own
# frame-blocking headers", and technitium_dns/nginx.conf for the fix.
export DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS="false"
export DNS_SERVER_WEB_SERVICE_HTTP_PORT="5381"
export DNS_SERVER_WEB_SERVICE_LOCAL_ADDRESSES="127.0.0.1"

# nginx, not Home Assistant's Ingress gateway, is now what connects to
# Technitium directly (both are in the same container, over loopback), so
# 127.0.0.1 is the address Technitium's own reverse-proxy trust check needs
# to see, not the Ingress gateway's own address.
export DNS_SERVER_WEB_SERVICE_REVERSE_PROXY_ADDRESSES="127.0.0.1"

# --- Web console access log (SOC audit tracking) --------------------------
# nginx.conf writes one JSON line per web console request here, including
# the Home Assistant user identity Ingress attaches to the request (not
# just an IP -- every request nginx sees comes from the Ingress gateway
# itself, so the IP alone would not distinguish users). This directory must
# exist before nginx starts, or nginx fails to open the log file. See
# docs/operations.md, "Web console access log for SOC audit tracking".
NGINX_LOG_DIR="/data/log/nginx"
ACCESS_LOG="${NGINX_LOG_DIR}/web_console_access.log"
mkdir -p "$NGINX_LOG_DIR"

ACCESS_LOG_RETENTION_DAYS="$(config_value 'web_console_access_log_retention_days' '90')"

# logrotate config regenerated on every start so a changed
# web_console_access_log_retention_days option takes effect on restart, not
# just before the container's own next start otherwise reads an old file.
# `rotate <N>` with `daily` keeps N once-a-day rotations, so this is treated
# as an approximate day count, not an exact one (a container that is not
# running when a day's rotation would have happened simply skips that day).
cat > /etc/logrotate.d/technitium-nginx-access <<EOF
${ACCESS_LOG} {
    daily
    rotate ${ACCESS_LOG_RETENTION_DAYS}
    compress
    missingok
    notifempty
    dateext
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 "\$(cat /run/nginx.pid)" 2>/dev/null || true
    endscript
}
EOF

# No cron daemon in this container; a plain daily loop calls logrotate
# itself instead. This dies with the container on stop/restart along with
# everything else in it, which is fine: it is re-created on every start.
(
    while true; do
        sleep 86400
        logrotate --state "${NGINX_LOG_DIR}/logrotate.state" /etc/logrotate.d/technitium-nginx-access
    done
) &

log_info "Starting the Ingress reverse proxy (nginx) on port 5380."
nginx

log_info "Handing off to Technitium DNS Server (config directory: ${CONFIG_DIR})."
exec /usr/bin/dotnet /opt/technitium/dns/DnsServerApp.dll "$CONFIG_DIR"
