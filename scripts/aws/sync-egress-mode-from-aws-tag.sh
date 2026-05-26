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