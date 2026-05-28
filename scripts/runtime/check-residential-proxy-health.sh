#!/usr/bin/env bash

set -euo pipefail

EGRESS_ENV_FILE="${EGRESS_ENV_FILE:-/etc/default/wireguard-egress}"
PROXY_SERVICE="${PROXY_SERVICE:-wg-residential-proxy.service}"
FIREWALL_SERVICE="${FIREWALL_SERVICE:-wg-firewall.service}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
LOCAL_CLOSE_WAIT_THRESHOLD="${LOCAL_CLOSE_WAIT_THRESHOLD:-64}"
LISTENER_BACKLOG_THRESHOLD="${LISTENER_BACKLOG_THRESHOLD:-64}"
RESTART_STATE_DIR="${RESTART_STATE_DIR:-/var/lib/wg-residential-proxy-health}"
RESTART_COOLDOWN_SECONDS="${RESTART_COOLDOWN_SECONDS:-120}"
MAX_RESTARTS_IN_WINDOW="${MAX_RESTARTS_IN_WINDOW:-3}"
RESTART_WINDOW_SECONDS="${RESTART_WINDOW_SECONDS:-300}"

log() {
    local message

    message="$1"
    echo "[wg-residential-proxy-health] ${message}"

    if command -v logger >/dev/null 2>&1; then
        logger -t wg-residential-proxy-health -- "${message}"
    fi
}

restart_proxy() {
    local reason
    local now
    local last_restart
    local recent_count

    reason="$1"

    install -d -m 700 "${RESTART_STATE_DIR}"
    now="$(date +%s)"

    if [[ -f "${RESTART_STATE_DIR}/last_restart" ]]; then
        last_restart="$(cat "${RESTART_STATE_DIR}/last_restart")"
        if (( now - last_restart < RESTART_COOLDOWN_SECONDS )); then
            log "Skipping restart (cooldown): last restart was $((now - last_restart))s ago, need ${RESTART_COOLDOWN_SECONDS}s"
            return 0
        fi
    fi

    recent_count="$(find "${RESTART_STATE_DIR}" -name 'restart_*' -mmin "-$((RESTART_WINDOW_SECONDS / 60 + 1))" 2>/dev/null | wc -l)"
    if (( recent_count >= MAX_RESTARTS_IN_WINDOW )); then
        log "Skipping restart (rate limit): ${recent_count} restarts in last ${RESTART_WINDOW_SECONDS}s, max is ${MAX_RESTARTS_IN_WINDOW}"
        return 0
    fi

    log "Restarting ${PROXY_SERVICE}: ${reason}"
    systemctl restart "${PROXY_SERVICE}"

    printf '%s' "${now}" > "${RESTART_STATE_DIR}/last_restart"
    touch "${RESTART_STATE_DIR}/restart_${now}"

    find "${RESTART_STATE_DIR}" -name 'restart_*' -mmin "+$((RESTART_WINDOW_SECONDS / 60 + 5))" -delete 2>/dev/null || true
}

listener_present() {
    local local_port

    local_port="$1"

    ss -ltnH | awk -v suffix=":${local_port}" '$4 ~ suffix"$" {found=1} END {exit(found ? 0 : 1)}'
}

listener_backlog() {
    local local_port

    local_port="$1"

    ss -ltnH | awk -v suffix=":${local_port}" '$4 ~ suffix"$" {print $2; found=1; exit} END {if (!found) print 0}'
}

count_local_close_wait() {
    local local_port

    local_port="$1"

    ss -tanH | awk -v suffix=":${local_port}" '$1 == "CLOSE-WAIT" && $4 ~ suffix"$" {count++} END {print count + 0}'
}

count_upstream_established() {
    local proxy_ip
    local proxy_port

    proxy_ip="$1"
    proxy_port="$2"

    if [[ -z "${proxy_ip}" || -z "${proxy_port}" ]]; then
        echo 0
        return
    fi

    ss -tanH | awk -v target="${proxy_ip}:${proxy_port}" '$1 == "ESTAB" && $5 == target {count++} END {print count + 0}'
}

if [[ -f "${EGRESS_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${EGRESS_ENV_FILE}"
fi

EGRESS_MODE="${EGRESS_MODE:-direct}"
RESIDENTIAL_PROXY_IP="${RESIDENTIAL_PROXY_IP:-}"
RESIDENTIAL_PROXY_PORT="${RESIDENTIAL_PROXY_PORT:-}"
RESIDENTIAL_PROXY_LOCAL_PORT="${RESIDENTIAL_PROXY_LOCAL_PORT:-12345}"

if [[ "${EGRESS_MODE}" != "residential-proxy" ]]; then
    exit 0
fi

if ! ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
    log "WARNING: WireGuard interface ${WG_INTERFACE} is missing - restarting wg-quick"
    systemctl restart "wg-quick@${WG_INTERFACE}" || true
    exit 0
fi

if ! systemctl is-active --quiet "${FIREWALL_SERVICE}"; then
    log "WARNING: Firewall service is inactive - restarting"
    systemctl restart "${FIREWALL_SERVICE}" || true
fi

if [[ "${RESIDENTIAL_PROXY_TYPE:-}" == "http-connect" && "${ENABLE_SOCKS5_UDP_SUPPORT:-false}" != "true" ]]; then
    if ! systemctl is-active --quiet systemd-resolved; then
        log "WARNING: systemd-resolved is inactive - restarting"
        systemctl restart systemd-resolved || true
    fi
fi

if ! systemctl is-active --quiet "${PROXY_SERVICE}"; then
    restart_proxy "service is inactive"
    exit 0
fi

if ! listener_present "${RESIDENTIAL_PROXY_LOCAL_PORT}"; then
    restart_proxy "listener missing on tcp/${RESIDENTIAL_PROXY_LOCAL_PORT}"
    exit 0
fi

local_close_wait="$(count_local_close_wait "${RESIDENTIAL_PROXY_LOCAL_PORT}")"
listener_recv_q="$(listener_backlog "${RESIDENTIAL_PROXY_LOCAL_PORT}")"
upstream_established="$(count_upstream_established "${RESIDENTIAL_PROXY_IP}" "${RESIDENTIAL_PROXY_PORT}")"

if (( listener_recv_q >= LISTENER_BACKLOG_THRESHOLD )); then
    restart_proxy "detected listener backlog ${listener_recv_q} on tcp/${RESIDENTIAL_PROXY_LOCAL_PORT}"
    exit 0
fi

if (( local_close_wait >= LOCAL_CLOSE_WAIT_THRESHOLD && upstream_established == 0 )); then
    restart_proxy "detected ${local_close_wait} CLOSE-WAIT sockets on tcp/${RESIDENTIAL_PROXY_LOCAL_PORT} and no established upstream proxy sessions"
fi