#!/usr/bin/env bash

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/default/wireguard-egress}"
PROXY_SERVICE="${PROXY_SERVICE:-wg-residential-proxy.service}"
UDP_PROXY_SERVICE="${UDP_PROXY_SERVICE:-wg-residential-udp-relay.service}"
FIREWALL_SERVICE="${FIREWALL_SERVICE:-wg-firewall.service}"
UDP_RELAY_CONFIG_FILE="${UDP_RELAY_CONFIG_FILE:-/etc/sing-box/wg-residential-udp-relay.json}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
ENABLE_SOCKS5_UDP_SUPPORT="${ENABLE_SOCKS5_UDP_SUPPORT:-false}"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="${RESIDENTIAL_PROXY_UDP_LOCAL_PORT:-12346}"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This command must be run as root or with sudo." >&2
        exit 1
    fi
}

load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
    fi

    EGRESS_MODE="${EGRESS_MODE:-direct}"
    RESIDENTIAL_PROXY_TYPE="${RESIDENTIAL_PROXY_TYPE:-socks5}"
    RESIDENTIAL_PROXY_HOST="${RESIDENTIAL_PROXY_HOST:-}"
    RESIDENTIAL_PROXY_IP="${RESIDENTIAL_PROXY_IP:-}"
    RESIDENTIAL_PROXY_PORT="${RESIDENTIAL_PROXY_PORT:-}"
    RESIDENTIAL_PROXY_USERNAME="${RESIDENTIAL_PROXY_USERNAME:-}"
    RESIDENTIAL_PROXY_PASSWORD="${RESIDENTIAL_PROXY_PASSWORD:-}"
    RESIDENTIAL_PROXY_LOCAL_PORT="${RESIDENTIAL_PROXY_LOCAL_PORT:-12345}"
    # DNS is handled by local dnscrypt-proxy (DoH) - no external DNS server needed
    ENABLE_SOCKS5_UDP_SUPPORT="${ENABLE_SOCKS5_UDP_SUPPORT:-false}"
    RESIDENTIAL_PROXY_UDP_LOCAL_PORT="${RESIDENTIAL_PROXY_UDP_LOCAL_PORT:-12346}"
}

escape_env_value() {
    local value

    value="${1//\\/\\\\}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    value="${value//\"/\\\"}"
    value="${value//\!/\\!}"
    printf '%s' "${value}"
}

resolve_ipv4() {
    local host

    host="$1"

    if [[ -z "${host}" ]]; then
        return 0
    fi

    if [[ "${host}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s' "${host}"
        return 0
    fi

    getent ahostsv4 "${host}" | awk 'NR == 1 {print $1; exit}'
}

server_address_ip() {
    ip -4 -o addr show dev "${WG_INTERFACE}" | awk 'NR == 1 {print $4}' | cut -d/ -f1
}

configure_dnscrypt_proxy() {
    local dnscrypt_config_file

    dnscrypt_config_file="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"

    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
        mkdir -p /var/cache/dnscrypt-proxy

        cat > "${dnscrypt_config_file}" <<'DNSCRYPT_EOF'
# dnscrypt-proxy configuration for DoH
# DNS traffic exits via redsocks proxy (port 443)

listen_addresses = ['127.0.0.1:5353']
max_clients = 50

# Only use DoH servers, disable legacy DNSCrypt
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true

# Privacy settings
require_dnssec = false
require_nolog = true
require_nofilter = true

# Force TCP so all DNS queries go through redsocks
force_tcp = true

# Timeouts
timeout = 5000
keepalive = 30

# Use multiple providers for redundancy
server_names = ['cloudflare', 'google']
fallback_resolver = '1.1.1.1:53'
ignore_system_dns = true

# Caching - reduce upstream queries
cache = true
cache_size = 512
cache_min_ttl = 600
cache_max_ttl = 86400

[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md']
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
DNSCRYPT_EOF

        systemctl enable dnscrypt-proxy
        systemctl restart dnscrypt-proxy
    else
        systemctl disable --now dnscrypt-proxy >/dev/null 2>&1 || true
    fi
}

configure_local_dns_listener() {
    local resolved_dropin_dir
    local resolved_dropin_file
    local local_dns_ip

    resolved_dropin_dir="/etc/systemd/resolved.conf.d"
    resolved_dropin_file="${resolved_dropin_dir}/99-wireguard-local-dns.conf"

    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
        local_dns_ip="$(server_address_ip)"

        if [[ -z "${local_dns_ip}" ]]; then
            echo "Unable to determine ${WG_INTERFACE} IPv4 address for local DNS listener." >&2
            exit 1
        fi

        install -d -m 755 "${resolved_dropin_dir}"
        # Use local dnscrypt-proxy DoH resolver (traffic exits via redsocks on port 443)
        cat > "${resolved_dropin_file}" <<EOF
[Resolve]
DNS=127.0.0.1:5353
FallbackDNS=
Domains=~.
DNSOverTLS=no
DNSStubListener=yes
DNSStubListenerExtra=${local_dns_ip}
EOF
    else
        rm -f "${resolved_dropin_file}"
    fi
}

write_env() {
    install -d -m 755 "$(dirname "${ENV_FILE}")"

    cat > "${ENV_FILE}" <<EOF
EGRESS_MODE="$(escape_env_value "${EGRESS_MODE}")"
RESIDENTIAL_PROXY_TYPE="$(escape_env_value "${RESIDENTIAL_PROXY_TYPE}")"
RESIDENTIAL_PROXY_HOST="$(escape_env_value "${RESIDENTIAL_PROXY_HOST}")"
RESIDENTIAL_PROXY_IP="$(escape_env_value "${RESIDENTIAL_PROXY_IP}")"
RESIDENTIAL_PROXY_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_PORT}")"
RESIDENTIAL_PROXY_USERNAME="$(escape_env_value "${RESIDENTIAL_PROXY_USERNAME}")"
RESIDENTIAL_PROXY_PASSWORD="$(escape_env_value "${RESIDENTIAL_PROXY_PASSWORD}")"
RESIDENTIAL_PROXY_LOCAL_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_LOCAL_PORT}")"
ENABLE_SOCKS5_UDP_SUPPORT="$(escape_env_value "${ENABLE_SOCKS5_UDP_SUPPORT}")"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}")"
EOF

    chmod 600 "${ENV_FILE}"
}

validate_proxy_settings() {
    case "${RESIDENTIAL_PROXY_TYPE}" in
        socks5|http-connect)
            ;;
        *)
            echo "Unsupported proxy type: ${RESIDENTIAL_PROXY_TYPE}" >&2
            exit 1
            ;;
    esac

    if [[ -z "${RESIDENTIAL_PROXY_HOST}" || -z "${RESIDENTIAL_PROXY_PORT}" ]]; then
        echo "Residential proxy requires host and port." >&2
        exit 1
    fi

    if [[ ! "${RESIDENTIAL_PROXY_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_PORT < 1 || RESIDENTIAL_PROXY_PORT > 65535 )); then
        echo "Residential proxy port must be between 1 and 65535." >&2
        exit 1
    fi

    if [[ ! "${RESIDENTIAL_PROXY_LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_LOCAL_PORT < 1 || RESIDENTIAL_PROXY_LOCAL_PORT > 65535 )); then
        echo "Residential proxy local redirect port must be between 1 and 65535." >&2
        exit 1
    fi

    case "${ENABLE_SOCKS5_UDP_SUPPORT}" in
        true|false)
            ;;
        *)
            echo "ENABLE_SOCKS5_UDP_SUPPORT must be true or false." >&2
            exit 1
            ;;
    esac

    if [[ ! "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_UDP_LOCAL_PORT < 1 || RESIDENTIAL_PROXY_UDP_LOCAL_PORT > 65535 )); then
        echo "Residential proxy UDP local redirect port must be between 1 and 65535." >&2
        exit 1
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" && "${RESIDENTIAL_PROXY_TYPE}" != "socks5" ]]; then
        echo "UDP support requires RESIDENTIAL_PROXY_TYPE=socks5." >&2
        exit 1
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" && "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}" == "${RESIDENTIAL_PROXY_LOCAL_PORT}" ]]; then
        echo "Residential proxy UDP and TCP local redirect ports must be different." >&2
        exit 1
    fi

    RESIDENTIAL_PROXY_IP="$(resolve_ipv4 "${RESIDENTIAL_PROXY_HOST}")"

    if [[ -z "${RESIDENTIAL_PROXY_IP}" ]]; then
        echo "Unable to resolve residential proxy host: ${RESIDENTIAL_PROXY_HOST}" >&2
        exit 1
    fi
}

udp_relay_ready() {
    command -v sing-box >/dev/null 2>&1 && [[ -f "${UDP_RELAY_CONFIG_FILE}" ]]
}

apply_services() {
    systemctl daemon-reload
    configure_dnscrypt_proxy
    configure_local_dns_listener

    if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
        systemctl enable "${PROXY_SERVICE}" >/dev/null
        systemctl restart "${PROXY_SERVICE}"

        if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]] && udp_relay_ready; then
            systemctl enable "${UDP_PROXY_SERVICE}" >/dev/null
            systemctl restart "${UDP_PROXY_SERVICE}"
        else
            systemctl disable --now "${UDP_PROXY_SERVICE}" >/dev/null 2>&1 || true
        fi
    else
        systemctl disable --now "${PROXY_SERVICE}" >/dev/null 2>&1 || true
        systemctl disable --now "${UDP_PROXY_SERVICE}" >/dev/null 2>&1 || true
    fi

    systemctl restart "${FIREWALL_SERVICE}"
    systemctl restart systemd-resolved
}

print_status() {
    load_env

    echo "Egress mode: ${EGRESS_MODE}"
    echo "Proxy type: ${RESIDENTIAL_PROXY_TYPE}"
    echo "Proxy host: ${RESIDENTIAL_PROXY_HOST:-<not configured>}"
    echo "Proxy IP: ${RESIDENTIAL_PROXY_IP:-<not configured>}"
    echo "Proxy port: ${RESIDENTIAL_PROXY_PORT:-<not configured>}"
    echo "Proxy local redirect port: ${RESIDENTIAL_PROXY_LOCAL_PORT}"
    echo "SOCKS5 UDP support: ${ENABLE_SOCKS5_UDP_SUPPORT}"
    echo "UDP local redirect port: ${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}"

    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
        echo "DNS upstream mode: systemd-resolved -> dnscrypt-proxy (DoH via redsocks)"
    fi

    if systemctl is-active --quiet "${PROXY_SERVICE}"; then
        echo "Residential proxy service: active"
    else
        echo "Residential proxy service: inactive"
    fi

    if systemctl is-active --quiet "${UDP_PROXY_SERVICE}"; then
        echo "UDP relay service: active"
    else
        echo "UDP relay service: inactive"
    fi

    if udp_relay_ready; then
        echo "UDP relay config: ready (${UDP_RELAY_CONFIG_FILE})"
    else
        echo "UDP relay config: missing (${UDP_RELAY_CONFIG_FILE})"
    fi
}

configure_proxy() {
    load_env

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                RESIDENTIAL_PROXY_HOST="$2"
                shift 2
                ;;
            --port)
                RESIDENTIAL_PROXY_PORT="$2"
                shift 2
                ;;
            --type)
                RESIDENTIAL_PROXY_TYPE="$2"
                shift 2
                ;;
            --username)
                RESIDENTIAL_PROXY_USERNAME="$2"
                shift 2
                ;;
            --password)
                RESIDENTIAL_PROXY_PASSWORD="$2"
                shift 2
                ;;
            --local-port)
                RESIDENTIAL_PROXY_LOCAL_PORT="$2"
                shift 2
                ;;
            --enable-udp)
                ENABLE_SOCKS5_UDP_SUPPORT="$2"
                shift 2
                ;;
            --udp-local-port)
                RESIDENTIAL_PROXY_UDP_LOCAL_PORT="$2"
                shift 2
                ;;
            *)
                echo "Unknown configure option: $1" >&2
                exit 1
                ;;
        esac
    done

    validate_proxy_settings
    write_env

    if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
        apply_services
    fi

    echo "Residential proxy profile saved."
    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]]; then
        echo "UDP relay plumbing enabled. Start an external TPROXY-capable UDP relay on port ${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}."
        if ! udp_relay_ready; then
            echo "Install sing-box and create ${UDP_RELAY_CONFIG_FILE}, then start ${UDP_PROXY_SERVICE}."
        fi
    fi
}

enable_proxy() {
    load_env
    validate_proxy_settings
    EGRESS_MODE="residential-proxy"
    write_env
    apply_services
    echo "Residential proxy mode enabled."
}

disable_proxy() {
    load_env
    EGRESS_MODE="direct"
    write_env
    apply_services
    echo "Residential proxy mode disabled."
}

remove_proxy() {
    load_env
    EGRESS_MODE="direct"
    RESIDENTIAL_PROXY_HOST=""
    RESIDENTIAL_PROXY_IP=""
    RESIDENTIAL_PROXY_PORT=""
    RESIDENTIAL_PROXY_USERNAME=""
    RESIDENTIAL_PROXY_PASSWORD=""
    ENABLE_SOCKS5_UDP_SUPPORT="false"
    RESIDENTIAL_PROXY_UDP_LOCAL_PORT="12346"
    write_env
    apply_services
    echo "Residential proxy profile removed."
}

usage() {
    cat <<'EOF'
Usage:
  wireguard-egress status
        wireguard-egress configure --host HOST --port PORT [--type socks5|http-connect] [--username USER] [--password PASS] [--local-port PORT] [--enable-udp true|false] [--udp-local-port PORT]
  wireguard-egress enable
  wireguard-egress disable
  wireguard-egress remove

Notes:
  - direct mode keeps the current AWS egress path
  - residential-proxy mode is strict fail-closed: only TCP traffic proxied through the upstream proxy
    - UDP is blocked by default (fail-closed); enable it only with SOCKS5 proxies that support UDP ASSOCIATE
    - If ENABLE_SOCKS5_UDP_SUPPORT=true, firewall will transparently intercept client UDP to RESIDENTIAL_PROXY_UDP_LOCAL_PORT
        - The project installs wg-residential-udp-relay.service as a sing-box wrapper; provide /etc/sing-box/wg-residential-udp-relay.json to use it
        - The bundled wg-residential-proxy service remains TCP-only
  - direct DNS from AWS is blocked in residential-proxy mode
  - if something breaks, switch back to direct mode and use AWS IP as the fallback egress
EOF
}

command_name="${1:-}"

case "${command_name}" in
    status)
        print_status
        ;;
    configure)
        require_root
        shift
        configure_proxy "$@"
        ;;
    enable)
        require_root
        enable_proxy
        ;;
    disable)
        require_root
        disable_proxy
        ;;
    remove)
        require_root
        remove_proxy
        ;;
    *)
        usage
        if [[ -n "${command_name}" ]]; then
            exit 1
        fi
        ;;
esac