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
RESIDENTIAL_DNS_UPSTREAM_IP="${RESIDENTIAL_DNS_UPSTREAM_IP:-54.72.70.84}"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="${RESIDENTIAL_PROXY_UDP_LOCAL_PORT:-12346}"

if [[ -f "${EGRESS_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${EGRESS_ENV_FILE}"
fi

if [[ -z "${UPLINK_IFACE}" ]]; then
    echo "Unable to determine uplink interface." >&2
    exit 1
fi

reset_policy_routing() {
    while ip rule del fwmark 0x1/0x1 lookup 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true
}

configure_policy_routing() {
    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]]; then
        ip rule add fwmark 0x1/0x1 lookup 100
        ip route add local 0.0.0.0/0 dev lo table 100
    fi
}

emit_filter_rules() {
    cat <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -d ${WG_NETWORK_CIDR} -j ACCEPT
-A OUTPUT -d 169.254.169.254/32 -j ACCEPT
-A OUTPUT -p udp --dport 53 -j ACCEPT
-A OUTPUT -p tcp --dport 53 -j ACCEPT
EOF

    if [[ -n "${RESIDENTIAL_PROXY_IP}" ]]; then
        echo "-A OUTPUT -d ${RESIDENTIAL_PROXY_IP}/32 -j ACCEPT"
    fi

    cat <<EOF
-A OUTPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p udp --dport ${WG_PORT} -j ACCEPT
EOF

    if [[ -n "${ALLOW_SSH_CIDR}" ]]; then
        echo "-A INPUT -p tcp -s ${ALLOW_SSH_CIDR} --dport 22 -j ACCEPT"
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

        cat <<EOF
-A INPUT -i ${WG_INTERFACE} -p tcp --dport ${RESIDENTIAL_PROXY_LOCAL_PORT} -j ACCEPT
-A FORWARD -i ${UPLINK_IFACE} -d ${WG_NETWORK_CIDR} -o ${WG_INTERFACE} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
EOF

        if [[ "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]]; then
            echo "-A INPUT -i ${WG_INTERFACE} -p udp --dport ${RESIDENTIAL_PROXY_UDP_LOCAL_PORT} -j ACCEPT"
        fi

        if [[ "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
            cat <<EOF
-A FORWARD -i ${WG_INTERFACE} -s ${WG_NETWORK_CIDR} -p udp --dport 53 -j ACCEPT
-A FORWARD -i ${WG_INTERFACE} -s ${WG_NETWORK_CIDR} -p tcp --dport 53 -j ACCEPT
EOF
        fi

        cat <<EOF
-A FORWARD -i ${WG_INTERFACE} -s ${WG_NETWORK_CIDR} -p tcp -j REJECT --reject-with tcp-reset
-A FORWARD -i ${WG_INTERFACE} -s ${WG_NETWORK_CIDR} -j REJECT --reject-with icmp-admin-prohibited
EOF
    else
        cat <<EOF
-A FORWARD -i ${WG_INTERFACE} -s ${WG_NETWORK_CIDR} -o ${UPLINK_IFACE} -j ACCEPT
-A FORWARD -i ${UPLINK_IFACE} -d ${WG_NETWORK_CIDR} -o ${WG_INTERFACE} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
EOF
    fi

    cat <<EOF
-A FORWARD -o ${WG_INTERFACE} -p icmp --icmp-type time-exceeded -j DROP
COMMIT
EOF
}

emit_nat_rules() {
    cat <<EOF
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
EOF

    if [[ "${EGRESS_MODE}" == "residential-proxy" ]]; then
        cat <<EOF
:WG_TCP_PROXY - [0:0]
EOF

        if [[ "${RESIDENTIAL_PROXY_TYPE}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT}" != "true" ]]; then
            cat <<EOF
-A POSTROUTING -s ${WG_NETWORK_CIDR} -p udp --dport 53 -o ${UPLINK_IFACE} -j MASQUERADE
-A POSTROUTING -s ${WG_NETWORK_CIDR} -p tcp --dport 53 -o ${UPLINK_IFACE} -j MASQUERADE
EOF
        fi

        cat <<EOF
-A WG_TCP_PROXY -d 0.0.0.0/8 -j RETURN
-A WG_TCP_PROXY -d 10.0.0.0/8 -j RETURN
-A WG_TCP_PROXY -d 127.0.0.0/8 -j RETURN
-A WG_TCP_PROXY -d 169.254.0.0/16 -j RETURN
-A WG_TCP_PROXY -d 172.16.0.0/12 -j RETURN
-A WG_TCP_PROXY -d 192.168.0.0/16 -j RETURN
-A WG_TCP_PROXY -d 224.0.0.0/4 -j RETURN
-A WG_TCP_PROXY -d 240.0.0.0/4 -j RETURN
-A WG_TCP_PROXY -d ${WG_NETWORK_CIDR} -j RETURN
-A WG_TCP_PROXY -d ${RESIDENTIAL_PROXY_IP}/32 -j RETURN
-A WG_TCP_PROXY -p tcp -j REDIRECT --to-ports ${RESIDENTIAL_PROXY_LOCAL_PORT}
-A PREROUTING -i ${WG_INTERFACE} -s ${WG_NETWORK_CIDR} -p tcp -j WG_TCP_PROXY
EOF
    else
        echo "-A POSTROUTING -s ${WG_NETWORK_CIDR} -o ${UPLINK_IFACE} -j MASQUERADE"
    fi

    echo "COMMIT"
}

emit_mangle_rules() {
    cat <<EOF
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
EOF

    if [[ "${EGRESS_MODE}" == "residential-proxy" && "${ENABLE_SOCKS5_UDP_SUPPORT}" == "true" ]]; then
        cat <<EOF
:WG_UDP_PROXY - [0:0]
-A WG_UDP_PROXY -d 0.0.0.0/8 -j RETURN
-A WG_UDP_PROXY -d 10.0.0.0/8 -j RETURN
-A WG_UDP_PROXY -d 127.0.0.0/8 -j RETURN
-A WG_UDP_PROXY -d 169.254.0.0/16 -j RETURN
-A WG_UDP_PROXY -d 172.16.0.0/12 -j RETURN
-A WG_UDP_PROXY -d 192.168.0.0/16 -j RETURN
-A WG_UDP_PROXY -d 224.0.0.0/4 -j RETURN
-A WG_UDP_PROXY -d 240.0.0.0/4 -j RETURN
-A WG_UDP_PROXY -d ${WG_NETWORK_CIDR} -j RETURN
-A WG_UDP_PROXY -d ${RESIDENTIAL_PROXY_IP}/32 -j RETURN
-A WG_UDP_PROXY -p udp -j TPROXY --on-port ${RESIDENTIAL_PROXY_UDP_LOCAL_PORT} --tproxy-mark 0x1/0x1
-A PREROUTING -i ${WG_INTERFACE} -s ${WG_NETWORK_CIDR} -p udp -j WG_UDP_PROXY
EOF
    fi

    echo "COMMIT"
}

apply_ipv4_rules() {
    local rules_file

    rules_file="$(mktemp)"

    {
        emit_filter_rules
        emit_nat_rules
        emit_mangle_rules
    } > "${rules_file}"

    iptables-restore < "${rules_file}"
    rm -f "${rules_file}"
}

apply_ipv6_policy() {
    if command -v ip6tables-restore >/dev/null 2>&1; then
        cat <<'EOF' | ip6tables-restore
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
EOF
    fi
}

reset_policy_routing
apply_ipv4_rules
configure_policy_routing
apply_ipv6_policy

install -d -m 700 /etc/iptables
iptables-save > /etc/iptables/rules.v4

if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > /etc/iptables/rules.v6
fi
