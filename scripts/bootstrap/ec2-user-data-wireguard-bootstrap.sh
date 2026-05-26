#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NETWORK_CIDR="10.44.0.0/24"
SERVER_ADDRESS_CIDR="10.44.0.1/24"
CLIENT_ADDRESS_CIDR="10.44.0.2/32"
CLIENT_DNS="1.1.1.1"
CLIENT_PUBLIC_KEY="REPLACE_WITH_PHONE_TEST_PUBLIC_KEY"
PRIMARY_CLIENT_NAME="phone-test-1"
PEER_DEFINITIONS="phone-test-1|REPLACE_WITH_PHONE_TEST_PUBLIC_KEY|10.44.0.2/32|1.1.1.1;cloud-test-1|REPLACE_WITH_CLOUD_TEST_PUBLIC_KEY|10.44.0.3/32|1.1.1.1"
ENABLE_SHARED_PROFILE="false"
SHARED_CLIENT_NAME="shared-client"
SHARED_CLIENT_PUBLIC_KEY=""
SHARED_CLIENT_ADDRESS_CIDR="10.44.0.250/32"
SHARED_CLIENT_DNS="1.1.1.1"
ALLOW_SSH_CIDR=""
EGRESS_MODE="direct"
RESIDENTIAL_PROXY_TYPE="socks5"
RESIDENTIAL_PROXY_HOST=""
RESIDENTIAL_PROXY_PORT=""
RESIDENTIAL_PROXY_USERNAME=""
RESIDENTIAL_PROXY_PASSWORD=""
RESIDENTIAL_PROXY_LOCAL_PORT="12345"
ENABLE_SOCKS5_UDP_SUPPORT="false"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="12346"
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="false"
AWS_EGRESS_TAG_KEY="wireguard-egress-mode"
AWS_EGRESS_SYNC_INTERVAL_SECONDS="30"

WIREGUARD_DIR="/etc/wireguard"
SERVER_PRIVATE_KEY_FILE="${WIREGUARD_DIR}/server.key"
SERVER_PUBLIC_KEY_FILE="${WIREGUARD_DIR}/server.pub"
FIREWALL_TARGET_FILE="/usr/local/sbin/apply-vpn-firewall.sh"
PROXY_RUNNER_TARGET_FILE="/usr/local/sbin/run-residential-proxy.sh"
UDP_PROXY_RUNNER_TARGET_FILE="/usr/local/sbin/run-residential-udp-relay.sh"
EGRESS_HELPER_TARGET_FILE="/usr/local/sbin/wireguard-egress"
AWS_EGRESS_SYNC_TARGET_FILE="/usr/local/sbin/sync-egress-mode-from-aws-tag.sh"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/wg-firewall.service"
PROXY_SYSTEMD_SERVICE_FILE="/etc/systemd/system/wg-residential-proxy.service"
UDP_PROXY_SYSTEMD_SERVICE_FILE="/etc/systemd/system/wg-residential-udp-relay.service"
AWS_EGRESS_SYNC_SERVICE_FILE="/etc/systemd/system/wg-egress-aws-sync.service"
AWS_EGRESS_SYNC_TIMER_FILE="/etc/systemd/system/wg-egress-aws-sync.timer"
CLIENT_TEMPLATE_FILE="/root/wireguard-client.conf"
SHARED_CLIENT_TEMPLATE_FILE="/root/wireguard-shared-client.conf"
CLIENT_TEMPLATE_DIR="/root/wireguard-clients"
PEER_STATE_DIR="${WIREGUARD_DIR}/peers"
EGRESS_ENV_FILE="/etc/default/wireguard-egress"
AWS_EGRESS_SYNC_ENV_FILE="/etc/default/wireguard-egress-aws-sync"

log() {
    echo "[wireguard-user-data] $*"
}

default_interface() {
    ip route list default | awk '/default/ {print $5; exit}'
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

sanitize_peer_name() {
    local peer_name

    peer_name="$1"
    peer_name="${peer_name,,}"
    peer_name="${peer_name// /-}"
    peer_name="${peer_name//[^a-z0-9._-]/}"
    printf '%s' "${peer_name}"
}

is_valid_wireguard_public_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

normalized_peer_definitions() {
    if [[ -n "${PEER_DEFINITIONS}" ]]; then
        printf '%s' "${PEER_DEFINITIONS}"
        return
    fi

    if [[ "${CLIENT_PUBLIC_KEY}" == "REPLACE_WITH_CLIENT_PUBLIC_KEY" || -z "${CLIENT_PUBLIC_KEY}" ]]; then
        log "Neither PEER_DEFINITIONS nor legacy CLIENT_PUBLIC_KEY was provided."
        exit 1
    fi

    printf '%s|%s|%s|%s' \
        "$(sanitize_peer_name "${PRIMARY_CLIENT_NAME}")" \
        "${CLIENT_PUBLIC_KEY}" \
        "${CLIENT_ADDRESS_CIDR}" \
        "${CLIENT_DNS}"
}

all_peer_definitions() {
    local definitions

    definitions="$(normalized_peer_definitions)"

    if [[ "${ENABLE_SHARED_PROFILE}" == "true" ]]; then
        if [[ -z "${SHARED_CLIENT_PUBLIC_KEY}" ]]; then
            log "SHARED_CLIENT_PUBLIC_KEY is required when ENABLE_SHARED_PROFILE=true."
            exit 1
        fi

        definitions+=";$(sanitize_peer_name "${SHARED_CLIENT_NAME}")|${SHARED_CLIENT_PUBLIC_KEY}|${SHARED_CLIENT_ADDRESS_CIDR}|${SHARED_CLIENT_DNS}"
    fi

    printf '%s' "${definitions}"
}

client_template_dns_line() {
    local peer_dns

    peer_dns="$1"

    if [[ -z "${peer_dns}" ]]; then
        return 0
    fi

    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
        return 0
    fi

    printf 'DNS = %s\n' "${peer_dns}"
}

validate_egress_settings() {
    case "${EGRESS_MODE}" in
        direct|residential-proxy)
            ;;
        *)
            log "Unsupported EGRESS_MODE: ${EGRESS_MODE}"
            exit 1
            ;;
    esac

    if [[ "${EGRESS_MODE}" != "residential-proxy" ]]; then
        return
    fi

    case "${RESIDENTIAL_PROXY_TYPE}" in
        socks5|http-connect)
            ;;
        *)
            log "Unsupported RESIDENTIAL_PROXY_TYPE: ${RESIDENTIAL_PROXY_TYPE}"
            exit 1
            ;;
    esac

    if [[ -z "${RESIDENTIAL_PROXY_HOST}" || -z "${RESIDENTIAL_PROXY_PORT}" ]]; then
        log "Residential proxy mode requires RESIDENTIAL_PROXY_HOST and RESIDENTIAL_PROXY_PORT."
        exit 1
    fi

    if [[ ! "${RESIDENTIAL_PROXY_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_PORT < 1 || RESIDENTIAL_PROXY_PORT > 65535 )); then
        log "RESIDENTIAL_PROXY_PORT must be between 1 and 65535."
        exit 1
    fi

    if [[ ! "${RESIDENTIAL_PROXY_LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_LOCAL_PORT < 1 || RESIDENTIAL_PROXY_LOCAL_PORT > 65535 )); then
        log "RESIDENTIAL_PROXY_LOCAL_PORT must be between 1 and 65535."
        exit 1
    fi

    case "${ENABLE_SOCKS5_UDP_SUPPORT}" in
        true|false)
            ;;
        *)
            log "ENABLE_SOCKS5_UDP_SUPPORT must be true or false."
            exit 1
            ;;
    esac

    if [[ ! "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_UDP_LOCAL_PORT < 1 || RESIDENTIAL_PROXY_UDP_LOCAL_PORT > 65535 )); then
        log "RESIDENTIAL_PROXY_UDP_LOCAL_PORT must be between 1 and 65535."
        exit 1
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" && "${RESIDENTIAL_PROXY_TYPE}" != "socks5" ]]; then
        log "ENABLE_SOCKS5_UDP_SUPPORT requires RESIDENTIAL_PROXY_TYPE=socks5."
        exit 1
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" && "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}" == "${RESIDENTIAL_PROXY_LOCAL_PORT}" ]]; then
        log "RESIDENTIAL_PROXY_UDP_LOCAL_PORT must be different from RESIDENTIAL_PROXY_LOCAL_PORT."
        exit 1
    fi

    if [[ -z "$(resolve_ipv4 "${RESIDENTIAL_PROXY_HOST}")" ]]; then
        log "Unable to resolve residential proxy host: ${RESIDENTIAL_PROXY_HOST}"
        exit 1
    fi
}

validate_aws_console_switch_settings() {
    case "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}" in
        true|false)
            ;;
        *)
            log "ENABLE_AWS_CONSOLE_EGRESS_SWITCH must be true or false."
            exit 1
            ;;
    esac

    if [[ ! "${AWS_EGRESS_SYNC_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || (( AWS_EGRESS_SYNC_INTERVAL_SECONDS < 5 )); then
        log "AWS_EGRESS_SYNC_INTERVAL_SECONDS must be at least 5 seconds."
        exit 1
    fi

    if [[ -z "${AWS_EGRESS_TAG_KEY}" ]]; then
        log "AWS_EGRESS_TAG_KEY must not be empty."
        exit 1
    fi
}

validate_peer_definitions() {
    local definitions
    local peer_entries
    local peer_entry
    local peer_name
    local peer_public_key
    local peer_address
    local peer_dns
    local sanitized_peer_name
    declare -A seen_public_keys=()
    declare -A seen_addresses=()

    definitions="$(all_peer_definitions)"
    IFS=';' read -r -a peer_entries <<< "${definitions}"

    for peer_entry in "${peer_entries[@]}"; do
        [[ -z "${peer_entry}" ]] && continue

        IFS='|' read -r peer_name peer_public_key peer_address peer_dns <<< "${peer_entry}"
        sanitized_peer_name="$(sanitize_peer_name "${peer_name}")"

        if [[ -z "${sanitized_peer_name}" || -z "${peer_public_key}" || -z "${peer_address}" ]]; then
            log "Invalid peer definition: ${peer_entry}"
            exit 1
        fi

        if ! is_valid_wireguard_public_key "${peer_public_key}"; then
            log "Invalid WireGuard public key for peer ${sanitized_peer_name}."
            exit 1
        fi

        if [[ -n "${seen_public_keys[${peer_public_key}]:-}" ]]; then
            log "Duplicate public key detected for peers ${seen_public_keys[${peer_public_key}]} and ${sanitized_peer_name}."
            log "WireGuard clients must not share the same key pair."
            exit 1
        fi

        if [[ -n "${seen_addresses[${peer_address}]:-}" ]]; then
            log "Duplicate client address detected for peers ${seen_addresses[${peer_address}]} and ${sanitized_peer_name}."
            exit 1
        fi

        seen_public_keys["${peer_public_key}"]="${sanitized_peer_name}"
        seen_addresses["${peer_address}"]="${sanitized_peer_name}"
    done
}

peer_psk_file() {
    local peer_name

    peer_name="$(sanitize_peer_name "$1")"
    printf '%s/%s.psk' "${PEER_STATE_DIR}" "${peer_name}"
}

ensure_peer_psk() {
    local psk_file

    psk_file="$(peer_psk_file "$1")"

    if [[ ! -f "${psk_file}" ]]; then
        umask 077
        wg genpsk > "${psk_file}"
    fi

    chmod 600 "${psk_file}"
}

log "Installing packages"
validate_peer_definitions
validate_egress_settings
validate_aws_console_switch_settings
apt-get update
apt-get install -y curl iptables iptables-persistent qrencode redsocks wireguard
systemctl disable --now redsocks.service >/dev/null 2>&1 || true

log "Applying sysctl settings"
cat > /etc/sysctl.d/99-wireguard-vpn.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
sysctl --system >/dev/null

log "Generating server keys"
install -d -m 700 "${WIREGUARD_DIR}"
install -d -m 700 "${PEER_STATE_DIR}"
umask 077
wg genkey | tee "${SERVER_PRIVATE_KEY_FILE}" | wg pubkey > "${SERVER_PUBLIC_KEY_FILE}"

log "Writing firewall script"
cat > "${FIREWALL_TARGET_FILE}" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_NETWORK_CIDR="${WG_NETWORK_CIDR:-10.44.0.0/24}"
UPLINK_IFACE="${UPLINK_IFACE:-$(ip route list default | awk '/default/ {print $5; exit}')}"
ALLOW_SSH_CIDR="${ALLOW_SSH_CIDR:-}"
EGRESS_ENV_FILE="${EGRESS_ENV_FILE:-/etc/default/wireguard-egress}"
EGRESS_MODE="${EGRESS_MODE:-direct}"
RESIDENTIAL_PROXY_TYPE="${RESIDENTIAL_PROXY_TYPE:-socks5}"
ENABLE_SOCKS5_UDP_SUPPORT="${ENABLE_SOCKS5_UDP_SUPPORT:-false}"
RESIDENTIAL_PROXY_IP="${RESIDENTIAL_PROXY_IP:-}"
RESIDENTIAL_PROXY_PORT="${RESIDENTIAL_PROXY_PORT:-}"
RESIDENTIAL_PROXY_LOCAL_PORT="${RESIDENTIAL_PROXY_LOCAL_PORT:-12345}"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="${RESIDENTIAL_PROXY_UDP_LOCAL_PORT:-12346}"

if [[ -f "${EGRESS_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${EGRESS_ENV_FILE}"
fi

if [[ -z "${UPLINK_IFACE}" ]]; then
    echo "Unable to determine uplink interface." >&2
    exit 1
fi

iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
iptables -t nat -X
iptables -t mangle -X

while ip rule del fwmark 0x1/0x1 lookup 100 2>/dev/null; do :; done
ip route flush table 100 2>/dev/null || true

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT

if [[ -n "${ALLOW_SSH_CIDR}" ]]; then
    iptables -A INPUT -p tcp -s "${ALLOW_SSH_CIDR}" --dport 22 -j ACCEPT
fi

if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
    if [[ -z "${RESIDENTIAL_PROXY_IP}" || -z "${RESIDENTIAL_PROXY_PORT}" ]]; then
        echo "Residential proxy mode requires RESIDENTIAL_PROXY_IP and RESIDENTIAL_PROXY_PORT." >&2
        exit 1
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" && "${RESIDENTIAL_PROXY_TYPE}" != "socks5" ]]; then
        echo "UDP support requires RESIDENTIAL_PROXY_TYPE=socks5." >&2
        exit 1
    fi

    iptables -A INPUT -i "${WG_INTERFACE}" -p tcp --dport "${RESIDENTIAL_PROXY_LOCAL_PORT}" -j ACCEPT
    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]]; then
        iptables -A INPUT -i "${WG_INTERFACE}" -p udp --dport "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}" -j ACCEPT

        iptables -t mangle -N WG_UDP_PROXY
        iptables -t mangle -A WG_UDP_PROXY -d 0.0.0.0/8 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d 10.0.0.0/8 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d 127.0.0.0/8 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d 169.254.0.0/16 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d 172.16.0.0/12 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d 192.168.0.0/16 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d 224.0.0.0/4 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d 240.0.0.0/4 -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d "${WG_NETWORK_CIDR}" -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -d "${RESIDENTIAL_PROXY_IP}/32" -j RETURN
        iptables -t mangle -A WG_UDP_PROXY -p udp -j TPROXY --on-port "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}" --tproxy-mark 0x1/0x1
        iptables -t mangle -A PREROUTING -i "${WG_INTERFACE}" -s "${WG_NETWORK_CIDR}" -p udp -j WG_UDP_PROXY

        ip rule add fwmark 0x1/0x1 lookup 100
        ip route add local 0.0.0.0/0 dev lo table 100
    fi

    iptables -A FORWARD -i "${UPLINK_IFACE}" -d "${WG_NETWORK_CIDR}" -o "${WG_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    iptables -t nat -N WG_TCP_PROXY
    iptables -t nat -A WG_TCP_PROXY -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d 240.0.0.0/4 -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d "${WG_NETWORK_CIDR}" -j RETURN
    iptables -t nat -A WG_TCP_PROXY -d "${RESIDENTIAL_PROXY_IP}/32" -j RETURN
    iptables -t nat -A WG_TCP_PROXY -p tcp -j REDIRECT --to-ports "${RESIDENTIAL_PROXY_LOCAL_PORT}"
    iptables -t nat -A PREROUTING -i "${WG_INTERFACE}" -s "${WG_NETWORK_CIDR}" -p tcp -j WG_TCP_PROXY
else
    iptables -A FORWARD -i "${WG_INTERFACE}" -s "${WG_NETWORK_CIDR}" -o "${UPLINK_IFACE}" -j ACCEPT
    iptables -A FORWARD -i "${UPLINK_IFACE}" -d "${WG_NETWORK_CIDR}" -o "${WG_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -t nat -A POSTROUTING -s "${WG_NETWORK_CIDR}" -o "${UPLINK_IFACE}" -j MASQUERADE
fi
iptables -A FORWARD -o "${WG_INTERFACE}" -p icmp --icmp-type time-exceeded -j DROP

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
fi

install -d -m 700 /etc/iptables
iptables-save > /etc/iptables/rules.v4

if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > /etc/iptables/rules.v6
fi
EOF
chmod 700 "${FIREWALL_TARGET_FILE}"

log "Writing residential proxy runner"
cat > "${PROXY_RUNNER_TARGET_FILE}" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

EGRESS_ENV_FILE="${EGRESS_ENV_FILE:-/etc/default/wireguard-egress}"
REDSOCKS_CONFIG_FILE="${REDSOCKS_CONFIG_FILE:-/run/wg-residential-proxy.conf}"

if [[ ! -f "${EGRESS_ENV_FILE}" ]]; then
    echo "Missing egress environment: ${EGRESS_ENV_FILE}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${EGRESS_ENV_FILE}"

EGRESS_MODE="${EGRESS_MODE:-direct}"
RESIDENTIAL_PROXY_TYPE="${RESIDENTIAL_PROXY_TYPE:-socks5}"
RESIDENTIAL_PROXY_IP="${RESIDENTIAL_PROXY_IP:-}"
RESIDENTIAL_PROXY_PORT="${RESIDENTIAL_PROXY_PORT:-}"
RESIDENTIAL_PROXY_USERNAME="${RESIDENTIAL_PROXY_USERNAME:-}"
RESIDENTIAL_PROXY_PASSWORD="${RESIDENTIAL_PROXY_PASSWORD:-}"
RESIDENTIAL_PROXY_LOCAL_PORT="${RESIDENTIAL_PROXY_LOCAL_PORT:-12345}"

escape_conf_value() {
    local value

    value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "${value}"
}

if [[ "${EGRESS_MODE}" != "residential-proxy" ]]; then
    echo "Residential proxy mode is disabled." >&2
    exit 1
fi

if [[ -z "${RESIDENTIAL_PROXY_IP}" || -z "${RESIDENTIAL_PROXY_PORT}" ]]; then
    echo "Residential proxy mode requires RESIDENTIAL_PROXY_IP and RESIDENTIAL_PROXY_PORT." >&2
    exit 1
fi

case "${RESIDENTIAL_PROXY_TYPE}" in
    socks5|http-connect)
        ;;
    *)
        echo "Unsupported residential proxy type: ${RESIDENTIAL_PROXY_TYPE}" >&2
        exit 1
        ;;
esac

REDSOCKS_BIN="$(command -v redsocks || true)"

if [[ -z "${REDSOCKS_BIN}" ]]; then
    echo "redsocks binary was not found in PATH." >&2
    exit 1
fi

login_line=""
password_line=""

if [[ -n "${RESIDENTIAL_PROXY_USERNAME}" ]]; then
    login_line="    login = \"$(escape_conf_value "${RESIDENTIAL_PROXY_USERNAME}")\";"
fi

if [[ -n "${RESIDENTIAL_PROXY_PASSWORD}" ]]; then
    password_line="    password = \"$(escape_conf_value "${RESIDENTIAL_PROXY_PASSWORD}")\";"
fi

cat > "${REDSOCKS_CONFIG_FILE}" <<REDSOCKS_EOF
base {
    log_debug = off;
    log_info = on;
    daemon = off;
    redirector = iptables;
}

redsocks {
    local_ip = 0.0.0.0;
    local_port = ${RESIDENTIAL_PROXY_LOCAL_PORT};
    ip = ${RESIDENTIAL_PROXY_IP};
    port = ${RESIDENTIAL_PROXY_PORT};
    type = ${RESIDENTIAL_PROXY_TYPE};
${login_line}
${password_line}
}
REDSOCKS_EOF

chmod 600 "${REDSOCKS_CONFIG_FILE}"

exec "${REDSOCKS_BIN}" -c "${REDSOCKS_CONFIG_FILE}"
EOF
chmod 700 "${PROXY_RUNNER_TARGET_FILE}"

log "Writing residential UDP relay runner"
cat > "${UDP_PROXY_RUNNER_TARGET_FILE}" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

EGRESS_ENV_FILE="${EGRESS_ENV_FILE:-/etc/default/wireguard-egress}"
SING_BOX_CONFIG_FILE="${SING_BOX_CONFIG_FILE:-/etc/sing-box/wg-residential-udp-relay.json}"

if [[ ! -f "${EGRESS_ENV_FILE}" ]]; then
    echo "Missing egress environment: ${EGRESS_ENV_FILE}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${EGRESS_ENV_FILE}"

EGRESS_MODE="${EGRESS_MODE:-direct}"
RESIDENTIAL_PROXY_TYPE="${RESIDENTIAL_PROXY_TYPE:-socks5}"
ENABLE_SOCKS5_UDP_SUPPORT="${ENABLE_SOCKS5_UDP_SUPPORT:-false}"

if [[ "${EGRESS_MODE}" != "residential-proxy" ]]; then
    echo "Residential proxy mode is disabled." >&2
    exit 1
fi

if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
    echo "SOCKS5 UDP relay support is disabled." >&2
    exit 1
fi

if [[ "${RESIDENTIAL_PROXY_TYPE}" != "socks5" ]]; then
    echo "UDP relay requires RESIDENTIAL_PROXY_TYPE=socks5." >&2
    exit 1
fi

SING_BOX_BIN="$(command -v sing-box || true)"

if [[ -z "${SING_BOX_BIN}" ]]; then
    echo "sing-box binary was not found in PATH." >&2
    exit 1
fi

if [[ ! -f "${SING_BOX_CONFIG_FILE}" ]]; then
    echo "Missing sing-box UDP relay config: ${SING_BOX_CONFIG_FILE}" >&2
    exit 1
fi

exec "${SING_BOX_BIN}" run -c "${SING_BOX_CONFIG_FILE}"
EOF
chmod 700 "${UDP_PROXY_RUNNER_TARGET_FILE}"

log "Writing egress helper"
cat > "${EGRESS_HELPER_TARGET_FILE}" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/default/wireguard-egress}"
PROXY_SERVICE="${PROXY_SERVICE:-wg-residential-proxy.service}"
UDP_PROXY_SERVICE="${UDP_PROXY_SERVICE:-wg-residential-udp-relay.service}"
FIREWALL_SERVICE="${FIREWALL_SERVICE:-wg-firewall.service}"
UDP_RELAY_CONFIG_FILE="${UDP_RELAY_CONFIG_FILE:-/etc/sing-box/wg-residential-udp-relay.json}"

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

write_env() {
    install -d -m 755 "$(dirname "${ENV_FILE}")"

    cat > "${ENV_FILE}" <<EGRESS_ENV_EOF
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
EGRESS_ENV_EOF

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
    cat <<'EOUSAGE'
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
EOUSAGE
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
EOF
chmod 700 "${EGRESS_HELPER_TARGET_FILE}"

log "Writing AWS Console egress sync helper"
cat > "${AWS_EGRESS_SYNC_TARGET_FILE}" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

AWS_EGRESS_ENV_FILE="${AWS_EGRESS_ENV_FILE:-/etc/default/wireguard-egress-aws-sync}"
EGRESS_HELPER_BIN="${EGRESS_HELPER_BIN:-/usr/local/sbin/wireguard-egress}"
IMDS_BASE_URL="${IMDS_BASE_URL:-http://169.254.169.254/latest}"
STATE_DIR="${STATE_DIR:-/var/lib/wireguard-egress}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/last-aws-tag-mode}"

if [[ ! -f "${AWS_EGRESS_ENV_FILE}" ]]; then
    exit 0
fi

# shellcheck disable=SC1090
source "${AWS_EGRESS_ENV_FILE}"

ENABLE_AWS_CONSOLE_EGRESS_SWITCH="${ENABLE_AWS_CONSOLE_EGRESS_SWITCH:-false}"
AWS_EGRESS_TAG_KEY="${AWS_EGRESS_TAG_KEY:-wireguard-egress-mode}"
AWS_EGRESS_ALLOWED_VALUES="${AWS_EGRESS_ALLOWED_VALUES:-direct residential-proxy}"

log() {
    echo "[wireguard-egress-aws-sync] $*"
}

fetch_imds_token() {
    curl -fsS -X PUT "${IMDS_BASE_URL}/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

fetch_instance_tag() {
    local token
    local encoded_key

    token="$1"
    encoded_key="${AWS_EGRESS_TAG_KEY// /%20}"

    curl -fsS \
        -H "X-aws-ec2-metadata-token: ${token}" \
        "${IMDS_BASE_URL}/meta-data/tags/instance/${encoded_key}"
}

mode_allowed() {
    local requested_mode
    local allowed_mode

    requested_mode="$1"

    for allowed_mode in ${AWS_EGRESS_ALLOWED_VALUES}; do
        if [[ "${requested_mode}" == "${allowed_mode}" ]]; then
            return 0
        fi
    done

    return 1
}

remember_mode() {
    local mode

    mode="$1"
    install -d -m 700 "${STATE_DIR}"
    printf '%s' "${mode}" > "${STATE_FILE}"
    chmod 600 "${STATE_FILE}"
}

last_mode() {
    if [[ -f "${STATE_FILE}" ]]; then
        cat "${STATE_FILE}"
    fi
}

if [[ "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}" != "true" ]]; then
    exit 0
fi

if [[ ! -x "${EGRESS_HELPER_BIN}" ]]; then
    log "Missing egress helper: ${EGRESS_HELPER_BIN}"
    exit 1
fi

token="$(fetch_imds_token)" || {
    log "Unable to fetch IMDSv2 token. Check whether instance metadata is enabled."
    exit 0
}

requested_mode="$(fetch_instance_tag "${token}" 2>/dev/null || true)"
requested_mode="${requested_mode//$'\r'/}"
requested_mode="${requested_mode//$'\n'/}"

if [[ -z "${requested_mode}" ]]; then
    exit 0
fi

if ! mode_allowed "${requested_mode}"; then
    log "Ignoring unsupported tag value '${requested_mode}' for ${AWS_EGRESS_TAG_KEY}."
    exit 0
fi

previous_mode="$(last_mode)"

if [[ "${requested_mode}" == "${previous_mode}" ]]; then
    exit 0
fi

case "${requested_mode}" in
    direct)
        "${EGRESS_HELPER_BIN}" disable
        ;;
    residential-proxy)
        "${EGRESS_HELPER_BIN}" enable
        ;;
esac

remember_mode "${requested_mode}"
log "Applied AWS tag switch ${AWS_EGRESS_TAG_KEY}=${requested_mode}."
EOF
chmod 700 "${AWS_EGRESS_SYNC_TARGET_FILE}"

log "Writing firewall environment"
cat > /etc/default/wireguard-firewall <<EOF
WG_INTERFACE="${WG_INTERFACE}"
WG_PORT="${WG_PORT}"
WG_NETWORK_CIDR="${WG_NETWORK_CIDR}"
UPLINK_IFACE="$(default_interface)"
ALLOW_SSH_CIDR="${ALLOW_SSH_CIDR}"
EOF

log "Writing egress environment"
cat > "${EGRESS_ENV_FILE}" <<EOF
EGRESS_MODE="$(escape_env_value "${EGRESS_MODE}")"
RESIDENTIAL_PROXY_TYPE="$(escape_env_value "${RESIDENTIAL_PROXY_TYPE}")"
RESIDENTIAL_PROXY_HOST="$(escape_env_value "${RESIDENTIAL_PROXY_HOST}")"
RESIDENTIAL_PROXY_IP="$(escape_env_value "$(resolve_ipv4 "${RESIDENTIAL_PROXY_HOST}")")"
RESIDENTIAL_PROXY_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_PORT}")"
RESIDENTIAL_PROXY_USERNAME="$(escape_env_value "${RESIDENTIAL_PROXY_USERNAME}")"
RESIDENTIAL_PROXY_PASSWORD="$(escape_env_value "${RESIDENTIAL_PROXY_PASSWORD}")"
RESIDENTIAL_PROXY_LOCAL_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_LOCAL_PORT}")"
ENABLE_SOCKS5_UDP_SUPPORT="$(escape_env_value "${ENABLE_SOCKS5_UDP_SUPPORT}")"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}")"
EOF
chmod 600 "${EGRESS_ENV_FILE}"

log "Writing AWS Console egress sync environment"
cat > "${AWS_EGRESS_SYNC_ENV_FILE}" <<EOF
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="$(escape_env_value "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}")"
AWS_EGRESS_TAG_KEY="$(escape_env_value "${AWS_EGRESS_TAG_KEY}")"
EOF
chmod 600 "${AWS_EGRESS_SYNC_ENV_FILE}"

log "Writing WireGuard config"
definitions="$(all_peer_definitions)"
IFS=';' read -r -a peer_entries <<< "${definitions}"

cat > "${WIREGUARD_DIR}/${WG_INTERFACE}.conf" <<EOF
[Interface]
Address = ${SERVER_ADDRESS_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${SERVER_PRIVATE_KEY_FILE}")
SaveConfig = false
EOF

for peer_entry in "${peer_entries[@]}"; do
    [[ -z "${peer_entry}" ]] && continue

    IFS='|' read -r peer_name peer_public_key peer_address peer_dns <<< "${peer_entry}"
    peer_name="$(sanitize_peer_name "${peer_name}")"

    if [[ -z "${peer_name}" || -z "${peer_public_key}" || -z "${peer_address}" ]]; then
        log "Invalid peer definition: ${peer_entry}"
        exit 1
    fi

    ensure_peer_psk "${peer_name}"

    cat >> "${WIREGUARD_DIR}/${WG_INTERFACE}.conf" <<EOF

[Peer]
PublicKey = ${peer_public_key}
PresharedKey = $(cat "$(peer_psk_file "${peer_name}")")
AllowedIPs = ${peer_address}
EOF
done
chmod 600 "${WIREGUARD_DIR}/${WG_INTERFACE}.conf"

log "Writing firewall systemd unit"
cat > "${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Apply firewall policy for WireGuard VPN
After=network-online.target
Wants=network-online.target
Before=wg-quick@${WG_INTERFACE}.service

[Service]
Type=oneshot
EnvironmentFile=/etc/default/wireguard-firewall
EnvironmentFile=${EGRESS_ENV_FILE}
ExecStart=${FIREWALL_TARGET_FILE}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

log "Writing residential proxy systemd unit"
cat > "${PROXY_SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Run residential proxy egress for WireGuard clients
After=network-online.target wg-firewall.service
Wants=network-online.target

[Service]
Type=simple
Environment=EGRESS_ENV_FILE=${EGRESS_ENV_FILE}
ExecStart=${PROXY_RUNNER_TARGET_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

log "Writing residential UDP relay systemd unit"
cat > "${UDP_PROXY_SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Run residential UDP relay for WireGuard clients
After=network-online.target wg-firewall.service
Wants=network-online.target

[Service]
Type=simple
Environment=EGRESS_ENV_FILE=${EGRESS_ENV_FILE}
Environment=SING_BOX_CONFIG_FILE=/etc/sing-box/wg-residential-udp-relay.json
ExecStart=${UDP_PROXY_RUNNER_TARGET_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

log "Writing AWS Console egress sync units"
cat > "${AWS_EGRESS_SYNC_SERVICE_FILE}" <<EOF
[Unit]
Description=Sync WireGuard egress mode from AWS instance tags
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=AWS_EGRESS_ENV_FILE=${AWS_EGRESS_SYNC_ENV_FILE}
ExecStart=${AWS_EGRESS_SYNC_TARGET_FILE}
EOF

cat > "${AWS_EGRESS_SYNC_TIMER_FILE}" <<EOF
[Unit]
Description=Poll AWS instance tags for WireGuard egress mode changes

[Timer]
OnBootSec=45s
OnUnitActiveSec=${AWS_EGRESS_SYNC_INTERVAL_SECONDS}s
Unit=wg-egress-aws-sync.service

[Install]
WantedBy=timers.target
EOF

log "Writing client templates"
install -d -m 700 "${CLIENT_TEMPLATE_DIR}"
primary_template_name="$(sanitize_peer_name "${PRIMARY_CLIENT_NAME}")"
shared_template_name="$(sanitize_peer_name "${SHARED_CLIENT_NAME}")"
found_primary="false"

for peer_entry in "${peer_entries[@]}"; do
    [[ -z "${peer_entry}" ]] && continue

    IFS='|' read -r peer_name peer_public_key peer_address peer_dns <<< "${peer_entry}"
    peer_name="$(sanitize_peer_name "${peer_name}")"

    if [[ -z "${peer_dns}" ]]; then
        peer_dns="${CLIENT_DNS}"
    fi

    cat > "${CLIENT_TEMPLATE_DIR}/${peer_name}.conf" <<EOF
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY_GOES_HERE
Address = ${peer_address}
$(client_template_dns_line "${peer_dns}")

[Peer]
PublicKey = $(cat "${SERVER_PUBLIC_KEY_FILE}")
PresharedKey = $(cat "$(peer_psk_file "${peer_name}")")
Endpoint = YOUR_ELASTIC_IP_OR_DNS:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "${CLIENT_TEMPLATE_DIR}/${peer_name}.conf"

    if [[ "${peer_name}" == "${primary_template_name}" ]]; then
        cp "${CLIENT_TEMPLATE_DIR}/${peer_name}.conf" "${CLIENT_TEMPLATE_FILE}"
        chmod 600 "${CLIENT_TEMPLATE_FILE}"
        found_primary="true"
    fi

    if [[ "${ENABLE_SHARED_PROFILE}" == "true" && "${peer_name}" == "${shared_template_name}" ]]; then
        cp "${CLIENT_TEMPLATE_DIR}/${peer_name}.conf" "${SHARED_CLIENT_TEMPLATE_FILE}"
        chmod 600 "${SHARED_CLIENT_TEMPLATE_FILE}"
    fi
done

if [[ "${found_primary}" != "true" ]]; then
    log "PRIMARY_CLIENT_NAME ${PRIMARY_CLIENT_NAME} was not found in PEER_DEFINITIONS."
    exit 1
fi

log "Enabling services"
systemctl daemon-reload
systemctl enable wg-firewall.service
systemctl start wg-firewall.service
if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
    systemctl enable wg-residential-proxy.service
    systemctl start wg-residential-proxy.service

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]] && command -v sing-box >/dev/null 2>&1 && [[ -f /etc/sing-box/wg-residential-udp-relay.json ]]; then
        systemctl enable wg-residential-udp-relay.service
        systemctl start wg-residential-udp-relay.service
    else
        systemctl disable --now wg-residential-udp-relay.service >/dev/null 2>&1 || true
    fi
else
    systemctl disable --now wg-residential-proxy.service >/dev/null 2>&1 || true
    systemctl disable --now wg-residential-udp-relay.service >/dev/null 2>&1 || true
fi
if [[ "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}" == "true" ]]; then
    systemctl enable wg-egress-aws-sync.timer
    systemctl restart wg-egress-aws-sync.timer
    systemctl start wg-egress-aws-sync.service
else
    systemctl disable --now wg-egress-aws-sync.timer >/dev/null 2>&1 || true
    systemctl stop wg-egress-aws-sync.service >/dev/null 2>&1 || true
fi
systemctl enable "wg-quick@${WG_INTERFACE}"
systemctl start "wg-quick@${WG_INTERFACE}"

log "Bootstrap completed"
log "Server public key: $(cat "${SERVER_PUBLIC_KEY_FILE}")"
log "Primary client template path: ${CLIENT_TEMPLATE_FILE}"
log "All client templates path: ${CLIENT_TEMPLATE_DIR}"
log "Egress mode: ${EGRESS_MODE}"
log "AWS Console egress switch: ${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}"
log "Egress helper path: ${EGRESS_HELPER_TARGET_FILE}"
if [[ "${ENABLE_SHARED_PROFILE}" == "true" ]]; then
    log "Shared client template path: ${SHARED_CLIENT_TEMPLATE_FILE}"
    log "Shared profile rule: only one shared-profile client should be active at a time."
fi
if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
    log "Residential proxy note: this mode is strict fail-closed. Traffic that cannot use the upstream proxy is blocked instead of leaking through AWS."
    if [[ "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
        log "DNS note: client UDP DNS is intentionally not configured in tcp-only http-connect mode."
        log "DNS note: use encrypted DNS over TCP/TLS/HTTPS on the client if you want name resolution through the tunnel."
    fi
    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]]; then
        log "UDP relay note: install sing-box config at /etc/sing-box/wg-residential-udp-relay.json, then start wg-residential-udp-relay.service."
    fi
fi
if [[ "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}" == "true" ]]; then
    log "AWS tag switch: set ${AWS_EGRESS_TAG_KEY}=direct or residential-proxy in EC2 tags."
fi

# Odczyt po wdrozeniu:
# - sudo ls -la /root/wireguard-clients
# - sudo cat /root/wireguard-client.conf
# - sudo wg show
# - sudo systemctl status wg-firewall.service wg-quick@wg0