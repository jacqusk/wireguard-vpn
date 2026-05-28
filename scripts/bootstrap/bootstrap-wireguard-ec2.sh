#!/usr/bin/env bash

set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_TUNNEL_MTU="${WG_TUNNEL_MTU:-1380}"
WG_NETWORK_CIDR="${WG_NETWORK_CIDR:-10.44.0.0/24}"
SERVER_ADDRESS_CIDR="${SERVER_ADDRESS_CIDR:-10.44.0.1/24}"
CLIENT_ADDRESS_CIDR="${CLIENT_ADDRESS_CIDR:-10.44.0.2/32}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
CLIENT_PUBLIC_KEY="${CLIENT_PUBLIC_KEY:-}"
PRIMARY_CLIENT_NAME="${PRIMARY_CLIENT_NAME:-ax3000}"
PEER_DEFINITIONS="${PEER_DEFINITIONS:-}"
ENABLE_SHARED_PROFILE="${ENABLE_SHARED_PROFILE:-false}"
SHARED_CLIENT_NAME="${SHARED_CLIENT_NAME:-shared-client}"
SHARED_CLIENT_PUBLIC_KEY="${SHARED_CLIENT_PUBLIC_KEY:-}"
SHARED_CLIENT_ADDRESS_CIDR="${SHARED_CLIENT_ADDRESS_CIDR:-10.44.0.250/32}"
SHARED_CLIENT_DNS="${SHARED_CLIENT_DNS:-1.1.1.1}"
ALLOW_SSH_CIDR="${ALLOW_SSH_CIDR:-}"
EGRESS_MODE="${EGRESS_MODE:-direct}"
RESIDENTIAL_PROXY_TYPE="${RESIDENTIAL_PROXY_TYPE:-socks5}"
RESIDENTIAL_PROXY_HOST="${RESIDENTIAL_PROXY_HOST:-}"
RESIDENTIAL_PROXY_PORT="${RESIDENTIAL_PROXY_PORT:-}"
RESIDENTIAL_PROXY_USERNAME="${RESIDENTIAL_PROXY_USERNAME:-}"
RESIDENTIAL_PROXY_PASSWORD="${RESIDENTIAL_PROXY_PASSWORD:-}"
RESIDENTIAL_PROXY_LOCAL_PORT="${RESIDENTIAL_PROXY_LOCAL_PORT:-12345}"
RESIDENTIAL_DNS_UPSTREAM_IP="${RESIDENTIAL_DNS_UPSTREAM_IP:-54.72.70.84}"
ENABLE_SOCKS5_UDP_SUPPORT="${ENABLE_SOCKS5_UDP_SUPPORT:-false}"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="${RESIDENTIAL_PROXY_UDP_LOCAL_PORT:-12346}"
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="${ENABLE_AWS_CONSOLE_EGRESS_SWITCH:-false}"
AWS_EGRESS_TAG_KEY="${AWS_EGRESS_TAG_KEY:-wireguard-egress-mode}"
AWS_EGRESS_SYNC_INTERVAL_SECONDS="${AWS_EGRESS_SYNC_INTERVAL_SECONDS:-30}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIREGUARD_DIR="/etc/wireguard"
SERVER_PRIVATE_KEY_FILE="${WIREGUARD_DIR}/server.key"
SERVER_PUBLIC_KEY_FILE="${WIREGUARD_DIR}/server.pub"
FIREWALL_SOURCE_FILE="${SCRIPT_DIR}/../firewall/apply-vpn-firewall.sh"
FIREWALL_TARGET_FILE="/usr/local/sbin/apply-vpn-firewall.sh"
PROXY_RUNNER_SOURCE_FILE="${SCRIPT_DIR}/../runtime/run-residential-proxy.sh"
PROXY_RUNNER_TARGET_FILE="/usr/local/sbin/run-residential-proxy.sh"
PROXY_HEALTHCHECK_SOURCE_FILE="${SCRIPT_DIR}/../runtime/check-residential-proxy-health.sh"
PROXY_HEALTHCHECK_TARGET_FILE="/usr/local/sbin/check-residential-proxy-health.sh"
UDP_PROXY_RUNNER_SOURCE_FILE="${SCRIPT_DIR}/../runtime/run-residential-udp-relay.sh"
UDP_PROXY_RUNNER_TARGET_FILE="/usr/local/sbin/run-residential-udp-relay.sh"
EGRESS_HELPER_SOURCE_FILE="${SCRIPT_DIR}/../runtime/wireguard-egress.sh"
EGRESS_HELPER_TARGET_FILE="/usr/local/sbin/wireguard-egress"
AWS_EGRESS_SYNC_SOURCE_FILE="${SCRIPT_DIR}/../aws/sync-egress-mode-from-aws-tag.sh"
AWS_EGRESS_SYNC_TARGET_FILE="/usr/local/sbin/sync-egress-mode-from-aws-tag.sh"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/wg-firewall.service"
PROXY_SYSTEMD_SERVICE_FILE="/etc/systemd/system/wg-residential-proxy.service"
PROXY_HEALTHCHECK_SERVICE_FILE="/etc/systemd/system/wg-residential-proxy-health.service"
PROXY_HEALTHCHECK_TIMER_FILE="/etc/systemd/system/wg-residential-proxy-health.timer"
UDP_PROXY_SYSTEMD_SERVICE_FILE="/etc/systemd/system/wg-residential-udp-relay.service"
AWS_EGRESS_SYNC_SERVICE_FILE="/etc/systemd/system/wg-egress-aws-sync.service"
AWS_EGRESS_SYNC_TIMER_FILE="/etc/systemd/system/wg-egress-aws-sync.timer"
CLIENT_TEMPLATE_FILE="/root/wireguard-client.conf"
SHARED_CLIENT_TEMPLATE_FILE="/root/wireguard-shared-client.conf"
CLIENT_TEMPLATE_DIR="/root/wireguard-clients"
PEER_STATE_DIR="${WIREGUARD_DIR}/peers"
EGRESS_ENV_FILE="/etc/default/wireguard-egress"
AWS_EGRESS_SYNC_ENV_FILE="/etc/default/wireguard-egress-aws-sync"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root or with sudo." >&2
        exit 1
    fi
}

require_peer_input() {
    if [[ -z "${PEER_DEFINITIONS}" && -z "${CLIENT_PUBLIC_KEY}" ]]; then
        echo "PEER_DEFINITIONS or legacy CLIENT_PUBLIC_KEY is required." >&2
        echo "Export one of them before running the script." >&2
        exit 1
    fi

    if [[ "${ENABLE_SHARED_PROFILE}" == "true" && -z "${SHARED_CLIENT_PUBLIC_KEY}" ]]; then
        echo "SHARED_CLIENT_PUBLIC_KEY is required when ENABLE_SHARED_PROFILE=true." >&2
        exit 1
    fi
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

validate_egress_settings() {
    case "${EGRESS_MODE}" in
        direct|residential-proxy)
            ;;
        *)
            echo "Unsupported EGRESS_MODE: ${EGRESS_MODE}" >&2
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
            echo "Unsupported RESIDENTIAL_PROXY_TYPE: ${RESIDENTIAL_PROXY_TYPE}" >&2
            exit 1
            ;;
    esac

    if [[ -z "${RESIDENTIAL_PROXY_HOST}" || -z "${RESIDENTIAL_PROXY_PORT}" ]]; then
        echo "Residential proxy mode requires RESIDENTIAL_PROXY_HOST and RESIDENTIAL_PROXY_PORT." >&2
        exit 1
    fi

    if [[ ! "${RESIDENTIAL_PROXY_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_PORT < 1 || RESIDENTIAL_PROXY_PORT > 65535 )); then
        echo "RESIDENTIAL_PROXY_PORT must be between 1 and 65535." >&2
        exit 1
    fi

    if [[ ! "${RESIDENTIAL_PROXY_LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( RESIDENTIAL_PROXY_LOCAL_PORT < 1 || RESIDENTIAL_PROXY_LOCAL_PORT > 65535 )); then
        echo "RESIDENTIAL_PROXY_LOCAL_PORT must be between 1 and 65535." >&2
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
        echo "RESIDENTIAL_PROXY_UDP_LOCAL_PORT must be between 1 and 65535." >&2
        exit 1
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" && "${RESIDENTIAL_PROXY_TYPE}" != "socks5" ]]; then
        echo "ENABLE_SOCKS5_UDP_SUPPORT requires RESIDENTIAL_PROXY_TYPE=socks5." >&2
        exit 1
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" && "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}" == "${RESIDENTIAL_PROXY_LOCAL_PORT}" ]]; then
        echo "RESIDENTIAL_PROXY_UDP_LOCAL_PORT must be different from RESIDENTIAL_PROXY_LOCAL_PORT." >&2
        exit 1
    fi


    if [[ -z "$(resolve_ipv4 "${RESIDENTIAL_PROXY_HOST}")" ]]; then
        echo "Unable to resolve residential proxy host: ${RESIDENTIAL_PROXY_HOST}" >&2
        exit 1
    fi
}

validate_aws_console_switch_settings() {
    case "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}" in
        true|false)
            ;;
        *)
            echo "ENABLE_AWS_CONSOLE_EGRESS_SWITCH must be true or false." >&2
            exit 1
            ;;
    esac

    if [[ ! "${AWS_EGRESS_SYNC_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || (( AWS_EGRESS_SYNC_INTERVAL_SECONDS < 5 )); then
        echo "AWS_EGRESS_SYNC_INTERVAL_SECONDS must be at least 5 seconds." >&2
        exit 1
    fi

    if [[ -z "${AWS_EGRESS_TAG_KEY}" ]]; then
        echo "AWS_EGRESS_TAG_KEY must not be empty." >&2
        exit 1
    fi
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
        definitions+=";$(sanitize_peer_name "${SHARED_CLIENT_NAME}")|${SHARED_CLIENT_PUBLIC_KEY}|${SHARED_CLIENT_ADDRESS_CIDR}|${SHARED_CLIENT_DNS}"
    fi

    printf '%s' "${definitions}"
}

server_address_ip() {
    printf '%s' "${SERVER_ADDRESS_CIDR%%/*}"
}

client_template_dns_line() {
    local peer_dns
    local dns_value

    peer_dns="$1"

    if [[ -z "${peer_dns}" ]]; then
        return 0
    fi

    dns_value="${peer_dns}"

    # In http-connect mode, force DNS to the configured upstream IP
    # Client connects directly, server only forwards the traffic
    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
        dns_value="${RESIDENTIAL_DNS_UPSTREAM_IP}"
    fi

    printf 'DNS = %s\n' "${dns_value}"
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
            echo "Invalid peer definition: ${peer_entry}" >&2
            exit 1
        fi

        if ! is_valid_wireguard_public_key "${peer_public_key}"; then
            echo "Invalid WireGuard public key for peer ${sanitized_peer_name}." >&2
            exit 1
        fi

        if [[ -n "${seen_public_keys[${peer_public_key}]:-}" ]]; then
            echo "Duplicate public key detected for peers ${seen_public_keys[${peer_public_key}]} and ${sanitized_peer_name}." >&2
            echo "WireGuard clients must not share the same key pair." >&2
            exit 1
        fi

        if [[ -n "${seen_addresses[${peer_address}]:-}" ]]; then
            echo "Duplicate client address detected for peers ${seen_addresses[${peer_address}]} and ${sanitized_peer_name}." >&2
            exit 1
        fi

        seen_public_keys["${peer_public_key}"]="${sanitized_peer_name}"
        seen_addresses["${peer_address}"]="${sanitized_peer_name}"
    done
}

default_interface() {
    ip route list default | awk '/default/ {print $5; exit}'
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

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl iptables iptables-persistent qrencode redsocks wireguard
        systemctl disable --now redsocks.service >/dev/null 2>&1 || true
}

prepare_sysctl() {
    cat > /etc/sysctl.d/99-wireguard-vpn.conf <<EOF
# Core network settings
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1

# TCP performance tuning for VPN
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.netfilter.nf_conntrack_max = 262144

# Small-instance memory tuning
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

    sysctl --system >/dev/null
}

configure_small_instance_memory() {
    local swap_file

    swap_file="/swapfile"

    systemctl disable --now snapd.service snapd.socket snapd.seeded.service multipathd.service multipathd.socket fwupd.service fwupd-refresh.service fwupd-refresh.timer ModemManager.service udisks2.service >/dev/null 2>&1 || true
    systemctl mask snapd.service snapd.socket snapd.seeded.service multipathd.service multipathd.socket fwupd.service fwupd-refresh.service fwupd-refresh.timer ModemManager.service udisks2.service >/dev/null 2>&1 || true

    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "${swap_file}"; then
        if [[ ! -f "${swap_file}" ]]; then
            fallocate -l 512M "${swap_file}" 2>/dev/null || dd if=/dev/zero of="${swap_file}" bs=1M count=512 status=none
            chmod 600 "${swap_file}"
            mkswap "${swap_file}" >/dev/null
        fi

        swapon "${swap_file}"
    fi

    if ! grep -Eq '^[^#]+[[:space:]]+/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
}

generate_keys() {
    install -d -m 700 "${WIREGUARD_DIR}"
    install -d -m 700 "${PEER_STATE_DIR}"

    if [[ ! -f "${SERVER_PRIVATE_KEY_FILE}" ]]; then
        umask 077
        wg genkey | tee "${SERVER_PRIVATE_KEY_FILE}" | wg pubkey > "${SERVER_PUBLIC_KEY_FILE}"
    fi
}

install_firewall_script() {
    if [[ ! -f "${FIREWALL_SOURCE_FILE}" ]]; then
        echo "Missing firewall script: ${FIREWALL_SOURCE_FILE}" >&2
        exit 1
    fi

    install -m 700 "${FIREWALL_SOURCE_FILE}" "${FIREWALL_TARGET_FILE}"
}

install_egress_scripts() {
    if [[ ! -f "${PROXY_RUNNER_SOURCE_FILE}" ]]; then
        echo "Missing residential proxy runner script: ${PROXY_RUNNER_SOURCE_FILE}" >&2
        exit 1
    fi

    if [[ ! -f "${PROXY_HEALTHCHECK_SOURCE_FILE}" ]]; then
        echo "Missing residential proxy healthcheck script: ${PROXY_HEALTHCHECK_SOURCE_FILE}" >&2
        exit 1
    fi

    if [[ ! -f "${EGRESS_HELPER_SOURCE_FILE}" ]]; then
        echo "Missing egress helper script: ${EGRESS_HELPER_SOURCE_FILE}" >&2
        exit 1
    fi

    if [[ ! -f "${UDP_PROXY_RUNNER_SOURCE_FILE}" ]]; then
        echo "Missing residential UDP relay runner script: ${UDP_PROXY_RUNNER_SOURCE_FILE}" >&2
        exit 1
    fi

    if [[ ! -f "${AWS_EGRESS_SYNC_SOURCE_FILE}" ]]; then
        echo "Missing AWS egress sync script: ${AWS_EGRESS_SYNC_SOURCE_FILE}" >&2
        exit 1
    fi

    install -m 700 "${PROXY_RUNNER_SOURCE_FILE}" "${PROXY_RUNNER_TARGET_FILE}"
    install -m 700 "${PROXY_HEALTHCHECK_SOURCE_FILE}" "${PROXY_HEALTHCHECK_TARGET_FILE}"
    install -m 700 "${UDP_PROXY_RUNNER_SOURCE_FILE}" "${UDP_PROXY_RUNNER_TARGET_FILE}"
    install -m 700 "${EGRESS_HELPER_SOURCE_FILE}" "${EGRESS_HELPER_TARGET_FILE}"
    install -m 700 "${AWS_EGRESS_SYNC_SOURCE_FILE}" "${AWS_EGRESS_SYNC_TARGET_FILE}"
}

write_firewall_environment() {
    cat > /etc/default/wireguard-firewall <<EOF
WG_INTERFACE="${WG_INTERFACE}"
WG_PORT="${WG_PORT}"
WG_NETWORK_CIDR="${WG_NETWORK_CIDR}"
UPLINK_IFACE="$(default_interface)"
ALLOW_SSH_CIDR="${ALLOW_SSH_CIDR}"
EOF
}

write_egress_environment() {
    local proxy_ip

    proxy_ip="$(resolve_ipv4 "${RESIDENTIAL_PROXY_HOST}")"

    cat > "${EGRESS_ENV_FILE}" <<EOF
EGRESS_MODE="$(escape_env_value "${EGRESS_MODE}")"
RESIDENTIAL_PROXY_TYPE="$(escape_env_value "${RESIDENTIAL_PROXY_TYPE}")"
RESIDENTIAL_PROXY_HOST="$(escape_env_value "${RESIDENTIAL_PROXY_HOST}")"
RESIDENTIAL_PROXY_IP="$(escape_env_value "${proxy_ip}")"
RESIDENTIAL_PROXY_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_PORT}")"
RESIDENTIAL_PROXY_USERNAME="$(escape_env_value "${RESIDENTIAL_PROXY_USERNAME}")"
RESIDENTIAL_PROXY_PASSWORD="$(escape_env_value "${RESIDENTIAL_PROXY_PASSWORD}")"
RESIDENTIAL_PROXY_LOCAL_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_LOCAL_PORT}")"
ENABLE_SOCKS5_UDP_SUPPORT="$(escape_env_value "${ENABLE_SOCKS5_UDP_SUPPORT}")"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="$(escape_env_value "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT}")"
EOF

    chmod 600 "${EGRESS_ENV_FILE}"
}

write_aws_console_switch_environment() {
    cat > "${AWS_EGRESS_SYNC_ENV_FILE}" <<EOF
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="$(escape_env_value "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}")"
AWS_EGRESS_TAG_KEY="$(escape_env_value "${AWS_EGRESS_TAG_KEY}")"
EOF

    chmod 600 "${AWS_EGRESS_SYNC_ENV_FILE}"
}

write_wireguard_config() {
    local definitions
    local peer_entries
    local peer_entry
    local peer_name
    local peer_public_key
    local peer_address
    local peer_dns
    local sanitized_peer_name
    local peer_psk

    definitions="$(all_peer_definitions)"
    IFS=';' read -r -a peer_entries <<< "${definitions}"

    cat > "${WIREGUARD_DIR}/${WG_INTERFACE}.conf" <<EOF
[Interface]
Address = ${SERVER_ADDRESS_CIDR}
ListenPort = ${WG_PORT}
MTU = ${WG_TUNNEL_MTU}
PrivateKey = $(cat "${SERVER_PRIVATE_KEY_FILE}")
SaveConfig = false
EOF

    for peer_entry in "${peer_entries[@]}"; do
        [[ -z "${peer_entry}" ]] && continue

        IFS='|' read -r peer_name peer_public_key peer_address peer_dns <<< "${peer_entry}"
        sanitized_peer_name="$(sanitize_peer_name "${peer_name}")"

        if [[ -z "${sanitized_peer_name}" || -z "${peer_public_key}" || -z "${peer_address}" ]]; then
            echo "Invalid peer definition: ${peer_entry}" >&2
            exit 1
        fi

        ensure_peer_psk "${sanitized_peer_name}"
        peer_psk="$(cat "$(peer_psk_file "${sanitized_peer_name}")")"

        cat >> "${WIREGUARD_DIR}/${WG_INTERFACE}.conf" <<EOF

[Peer]
PublicKey = ${peer_public_key}
PresharedKey = ${peer_psk}
AllowedIPs = ${peer_address}
EOF
    done

    chmod 600 "${WIREGUARD_DIR}/${WG_INTERFACE}.conf"
}

write_systemd_service() {
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
}

write_proxy_systemd_service() {
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
}

write_proxy_healthcheck_units() {
    cat > "${PROXY_HEALTHCHECK_SERVICE_FILE}" <<EOF
[Unit]
Description=Watch residential proxy egress health for WireGuard clients
After=network-online.target wg-residential-proxy.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=EGRESS_ENV_FILE=${EGRESS_ENV_FILE}
Environment=PROXY_SERVICE=wg-residential-proxy.service
ExecStart=${PROXY_HEALTHCHECK_TARGET_FILE}
EOF

    cat > "${PROXY_HEALTHCHECK_TIMER_FILE}" <<EOF
[Unit]
Description=Periodically validate residential proxy egress health

[Timer]
OnBootSec=60s
OnUnitActiveSec=30s
Unit=wg-residential-proxy-health.service

[Install]
WantedBy=timers.target
EOF
}

write_udp_proxy_systemd_service() {
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
}

udp_relay_ready() {
    command -v sing-box >/dev/null 2>&1 && [[ -f /etc/sing-box/wg-residential-udp-relay.json ]]
}

write_aws_console_sync_units() {
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
}

write_config_watcher_units() {
    cat > /etc/systemd/system/wireguard-egress-config.path <<EOF
[Unit]
Description=Watch for wireguard-egress config changes

[Path]
PathModified=${EGRESS_ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/wireguard-egress-config.service <<EOF
[Unit]
Description=Reload firewall after egress config change

[Service]
Type=oneshot
ExecStart=${FIREWALL_TARGET_FILE}
ExecStart=/bin/systemctl restart wg-residential-proxy.service
EOF
}

write_client_templates() {
    local definitions
    local peer_entries
    local peer_entry
    local peer_name
    local peer_public_key
    local peer_address
    local peer_dns
    local sanitized_peer_name
    local peer_psk
    local peer_template_file
    local primary_template_name
    local found_primary
    local shared_template_name

    definitions="$(all_peer_definitions)"
    IFS=';' read -r -a peer_entries <<< "${definitions}"
    primary_template_name="$(sanitize_peer_name "${PRIMARY_CLIENT_NAME}")"
    shared_template_name="$(sanitize_peer_name "${SHARED_CLIENT_NAME}")"
    found_primary="false"

    install -d -m 700 "${CLIENT_TEMPLATE_DIR}"

    for peer_entry in "${peer_entries[@]}"; do
        [[ -z "${peer_entry}" ]] && continue

        IFS='|' read -r peer_name peer_public_key peer_address peer_dns <<< "${peer_entry}"
        sanitized_peer_name="$(sanitize_peer_name "${peer_name}")"

        if [[ -z "${peer_dns}" ]]; then
            peer_dns="${CLIENT_DNS}"
        fi

        peer_psk="$(cat "$(peer_psk_file "${sanitized_peer_name}")")"
        peer_template_file="${CLIENT_TEMPLATE_DIR}/${sanitized_peer_name}.conf"

        cat > "${peer_template_file}" <<EOF
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY_GOES_HERE
Address = ${peer_address}
$(client_template_dns_line "${peer_dns}")
MTU = ${WG_TUNNEL_MTU}

[Peer]
PublicKey = $(cat "${SERVER_PUBLIC_KEY_FILE}")
PresharedKey = ${peer_psk}
Endpoint = YOUR_ELASTIC_IP_OR_DNS:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

        chmod 600 "${peer_template_file}"

        if [[ "${sanitized_peer_name}" == "${primary_template_name}" ]]; then
            cp "${peer_template_file}" "${CLIENT_TEMPLATE_FILE}"
            chmod 600 "${CLIENT_TEMPLATE_FILE}"
            found_primary="true"
        fi

        if [[ "${ENABLE_SHARED_PROFILE}" == "true" && "${sanitized_peer_name}" == "${shared_template_name}" ]]; then
            cp "${peer_template_file}" "${SHARED_CLIENT_TEMPLATE_FILE}"
            chmod 600 "${SHARED_CLIENT_TEMPLATE_FILE}"
        fi
    done

    if [[ "${found_primary}" != "true" ]]; then
        echo "Primary client ${PRIMARY_CLIENT_NAME} was not found in PEER_DEFINITIONS." >&2
        exit 1
    fi
}

start_services() {
    systemctl daemon-reload
    systemctl enable wg-firewall.service
    systemctl restart wg-firewall.service
    if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
        systemctl enable wg-residential-proxy.service
        systemctl restart wg-residential-proxy.service
        systemctl enable wg-residential-proxy-health.timer
        systemctl restart wg-residential-proxy-health.timer
        systemctl start wg-residential-proxy-health.service
        if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]] && udp_relay_ready; then
            systemctl enable wg-residential-udp-relay.service
            systemctl restart wg-residential-udp-relay.service
        else
            systemctl disable --now wg-residential-udp-relay.service >/dev/null 2>&1 || true
        fi
    else
        systemctl disable --now wg-residential-proxy.service >/dev/null 2>&1 || true
        systemctl disable --now wg-residential-proxy-health.timer >/dev/null 2>&1 || true
        systemctl stop wg-residential-proxy-health.service >/dev/null 2>&1 || true
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
    systemctl restart "wg-quick@${WG_INTERFACE}"
    systemctl enable --now wireguard-egress-config.path
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
}

print_summary() {
    echo
    echo "WireGuard bootstrap completed."
    echo "Server public key: $(cat "${SERVER_PUBLIC_KEY_FILE}")"
    echo "Primary client template: ${CLIENT_TEMPLATE_FILE}"
    echo "All client templates: ${CLIENT_TEMPLATE_DIR}"
    echo "Egress mode: ${EGRESS_MODE}"
    echo "AWS Console egress switch: ${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}"
    if [[ "${ENABLE_SHARED_PROFILE}" == "true" ]]; then
        echo "Shared client template: ${SHARED_CLIENT_TEMPLATE_FILE}"
        echo "Shared profile rule: only one shared-profile client should be active at a time."
    fi
    echo "Egress helper: ${EGRESS_HELPER_TARGET_FILE}"
    echo "Firewall config: /etc/default/wireguard-firewall"
    echo "Egress config: ${EGRESS_ENV_FILE}"
    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
        echo "DNS note: client DNS is set to ${RESIDENTIAL_DNS_UPSTREAM_IP} (forwarded by server, not proxied)."
        echo "Proxy note: a health timer checks the local transparent proxy every 30 seconds."
    fi
    echo
    echo "Primary client template content for AWS system log retrieval:"
    echo "-----BEGIN PRIMARY CLIENT TEMPLATE-----"
    cat "${CLIENT_TEMPLATE_FILE}"
    echo "-----END PRIMARY CLIENT TEMPLATE-----"
    if [[ "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}" == "true" ]]; then
        echo "AWS tag switch: set ${AWS_EGRESS_TAG_KEY}=direct or residential-proxy in EC2 tags."
    fi
    echo
    echo "Next steps:"
    echo "1. Replace YOUR_ELASTIC_IP_OR_DNS in each file under ${CLIENT_TEMPLATE_DIR}."
    echo "2. Replace CLIENT_PRIVATE_KEY_GOES_HERE with the private key generated on each client."
    echo "3. Import the matching client config into AX3000 and any optional phones."
    echo "4. Optional residential proxy flow: use sudo wireguard-egress configure/enable/disable/remove on the EC2 instance."
    if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
        echo "Residential proxy note: this mode is strict fail-closed. Traffic that cannot use the upstream proxy is blocked instead of leaking through AWS."
        if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]]; then
            echo "UDP relay note: install sing-box config at /etc/sing-box/wg-residential-udp-relay.json, then start wg-residential-udp-relay.service."
        fi
    fi
}

main() {
    require_root
    require_peer_input
    validate_peer_definitions
    validate_egress_settings
    validate_aws_console_switch_settings
    install_packages
    prepare_sysctl
    configure_small_instance_memory
    generate_keys
    install_firewall_script
    install_egress_scripts
    write_firewall_environment
    write_egress_environment
    write_aws_console_switch_environment
    write_wireguard_config
    write_systemd_service
    write_proxy_systemd_service
    write_proxy_healthcheck_units
    write_udp_proxy_systemd_service
    write_aws_console_sync_units
    write_config_watcher_units
    write_client_templates
    start_services
    print_summary
}

main "$@"