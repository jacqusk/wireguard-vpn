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