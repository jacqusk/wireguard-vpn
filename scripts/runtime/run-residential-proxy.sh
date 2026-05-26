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

cat > "${REDSOCKS_CONFIG_FILE}" <<EOF
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
EOF

chmod 600 "${REDSOCKS_CONFIG_FILE}"

exec "${REDSOCKS_BIN}" -c "${REDSOCKS_CONFIG_FILE}"