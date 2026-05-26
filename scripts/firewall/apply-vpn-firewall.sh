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

# Reset IPv4 rules so the policy can be re-applied idempotently.
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

        # Transparent UDP interception needs a separate local relay listening on
        # RESIDENTIAL_PROXY_UDP_LOCAL_PORT with TPROXY support.
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
    iptables -t nat -A WG_TCP_PROXY -j REDIRECT --to-ports "${RESIDENTIAL_PROXY_LOCAL_PORT}"
    iptables -t nat -A PREROUTING -i "${WG_INTERFACE}" -s "${WG_NETWORK_CIDR}" -p tcp -j WG_TCP_PROXY
else
    # Forward only traffic that arrives from the WireGuard tunnel.
    iptables -A FORWARD -i "${WG_INTERFACE}" -s "${WG_NETWORK_CIDR}" -o "${UPLINK_IFACE}" -j ACCEPT
    iptables -A FORWARD -i "${UPLINK_IFACE}" -d "${WG_NETWORK_CIDR}" -o "${WG_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # NAT client traffic so outbound requests use the AWS public IP.
    iptables -t nat -A POSTROUTING -s "${WG_NETWORK_CIDR}" -o "${UPLINK_IFACE}" -j MASQUERADE
fi

# Hide intermediate hops from traceroute-style commands returning to the client.
iptables -A FORWARD -o "${WG_INTERFACE}" -p icmp --icmp-type time-exceeded -j DROP

# Keep IPv6 disabled to avoid accidental egress leaks outside the IPv4-only tunnel.
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