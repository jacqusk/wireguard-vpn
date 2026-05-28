#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/health/validate-residential-proxy-cutover-inputs.sh \
    --preflight PATH_TO_PREFLIGHT_ENV \
    --user-data PATH_TO_USER_DATA_ENV

Notes:
  - input files must be trusted local files in KEY="VALUE" form
  - this validator is intended for a replacement rollout that boots directly into residential-proxy mode
EOF
}

fail() {
    echo "Validation failed: $*" >&2
    exit 1
}

require_file() {
    local path

    path="$1"

    [[ -f "${path}" ]] || fail "missing file: ${path}"
}

require_value() {
    local name
    local value

    name="$1"
    value="$2"

    [[ -n "${value}" ]] || fail "${name} must not be empty"
}

require_not_placeholder() {
    local name
    local value

    name="$1"
    value="$2"

    [[ "${value}" != REPLACE_WITH_* ]] || fail "${name} still contains a placeholder value"
    [[ "${value}" != *REPLACE_WITH_* ]] || fail "${name} still contains a placeholder value"
}

require_boolean() {
    local name
    local value

    name="$1"
    value="$2"

    case "${value}" in
        true|false)
            ;;
        *)
            fail "${name} must be true or false"
            ;;
    esac
}

require_equals() {
    local name
    local value
    local expected

    name="$1"
    value="$2"
    expected="$3"

    [[ "${value}" == "${expected}" ]] || fail "${name} must be '${expected}', got '${value}'"
}

require_wireguard_public_key() {
    local name
    local value

    name="$1"
    value="$2"

    [[ "${value}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "${name} is not a valid WireGuard public key"
}

require_ipv4_cidr_32() {
    local name
    local value

    name="$1"
    value="$2"

    [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || fail "${name} must be an IPv4 /32 CIDR"
}

require_account_id() {
    local value

    value="$1"

    [[ "${value}" =~ ^[0-9]{12}$ ]] || fail "TARGET_AWS_ACCOUNT_ID must be a 12-digit AWS account ID"
}

require_port() {
    local name
    local value

    name="$1"
    value="$2"

    [[ "${value}" =~ ^[0-9]+$ ]] || fail "${name} must be numeric"
    (( value >= 1 && value <= 65535 )) || fail "${name} must be between 1 and 65535"
}

parse_args() {
    PREFLIGHT_FILE=""
    USER_DATA_FILE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --preflight)
                PREFLIGHT_FILE="$2"
                shift 2
                ;;
            --user-data)
                USER_DATA_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "unknown argument: $1"
                ;;
        esac
    done

    require_value "PREFLIGHT_FILE" "${PREFLIGHT_FILE}"
    require_value "USER_DATA_FILE" "${USER_DATA_FILE}"
}

load_env_file() {
    local path

    path="$1"
    require_file "${path}"
    # shellcheck disable=SC1090
    source "${path}"
}

validate_preflight() {
    require_value "TARGET_AWS_ACCOUNT_NAME" "${TARGET_AWS_ACCOUNT_NAME:-}"
    require_not_placeholder "TARGET_AWS_ACCOUNT_NAME" "${TARGET_AWS_ACCOUNT_NAME:-}"
    require_value "TARGET_AWS_ACCOUNT_ID" "${TARGET_AWS_ACCOUNT_ID:-}"
    require_not_placeholder "TARGET_AWS_ACCOUNT_ID" "${TARGET_AWS_ACCOUNT_ID:-}"
    require_account_id "${TARGET_AWS_ACCOUNT_ID:-}"
    require_value "TARGET_AWS_REGION" "${TARGET_AWS_REGION:-}"
    require_not_placeholder "TARGET_GITHUB_OWNER" "${TARGET_GITHUB_OWNER:-}"
    require_not_placeholder "TARGET_GITHUB_REPO" "${TARGET_GITHUB_REPO:-}"
    require_value "TARGET_GITHUB_BRANCH" "${TARGET_GITHUB_BRANCH:-}"

    require_value "EC2_INSTANCE_NAME" "${EC2_INSTANCE_NAME:-}"
    require_value "SECURITY_GROUP_NAME" "${SECURITY_GROUP_NAME:-}"
    require_value "ELASTIC_IP_NAME" "${ELASTIC_IP_NAME:-}"

    require_equals "ALLOW_SSH" "${ALLOW_SSH:-}" "false"
    require_equals "ALLOW_SSM" "${ALLOW_SSM:-}" "false"
    require_equals "ENABLE_AWS_CONSOLE_EGRESS_SWITCH" "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH:-}" "false"
    require_equals "ENABLE_RESIDENTIAL_PROXY" "${ENABLE_RESIDENTIAL_PROXY:-}" "true"
    require_boolean "ENABLE_UDP_RELAY" "${ENABLE_UDP_RELAY:-false}"

    require_value "PRIMARY_TEST_PEER_NAME" "${PRIMARY_TEST_PEER_NAME:-}"
    require_value "CLIENT_DNS" "${CLIENT_DNS:-}"
}

validate_peer_definitions() {
    local definitions
    local entries
    local entry
    local peer_name
    local peer_public_key
    local peer_address
    local peer_dns
    local primary_found
    local secondary_found

    definitions="${PEER_DEFINITIONS:-}"
    require_value "PEER_DEFINITIONS" "${definitions}"
    require_not_placeholder "PEER_DEFINITIONS" "${definitions}"

    primary_found="false"
    secondary_found="false"
    IFS=';' read -r -a entries <<< "${definitions}"

    for entry in "${entries[@]}"; do
        [[ -z "${entry}" ]] && continue

        IFS='|' read -r peer_name peer_public_key peer_address peer_dns <<< "${entry}"

        require_value "peer name" "${peer_name}"
        require_value "peer public key" "${peer_public_key}"
        require_value "peer address" "${peer_address}"
        require_value "peer dns" "${peer_dns}"
        require_wireguard_public_key "public key for ${peer_name}" "${peer_public_key}"
        require_ipv4_cidr_32 "address for ${peer_name}" "${peer_address}"

        [[ "${peer_name}" =~ ^[a-z0-9._-]+$ ]] || fail "peer name '${peer_name}' contains unsupported characters"

        if [[ "${peer_name}" == "${PRIMARY_TEST_PEER_NAME}" ]]; then
            primary_found="true"
        fi

        if [[ -n "${SECONDARY_TEST_PEER_NAME:-}" && "${peer_name}" == "${SECONDARY_TEST_PEER_NAME}" ]]; then
            secondary_found="true"
        fi
    done

    [[ "${primary_found}" == "true" ]] || fail "PRIMARY_TEST_PEER_NAME is not present in PEER_DEFINITIONS"

    if [[ -n "${SECONDARY_TEST_PEER_NAME:-}" ]]; then
        [[ "${secondary_found}" == "true" ]] || fail "SECONDARY_TEST_PEER_NAME is not present in PEER_DEFINITIONS"
    fi
}

validate_user_data_values() {
    require_value "PRIMARY_CLIENT_NAME" "${PRIMARY_CLIENT_NAME:-}"
    require_equals "PRIMARY_CLIENT_NAME" "${PRIMARY_CLIENT_NAME:-}" "${PRIMARY_TEST_PEER_NAME:-}"
    require_equals "EGRESS_MODE" "${EGRESS_MODE:-}" "residential-proxy"
    require_equals "ENABLE_AWS_CONSOLE_EGRESS_SWITCH" "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH:-}" "false"
    require_boolean "ENABLE_SOCKS5_UDP_SUPPORT" "${ENABLE_SOCKS5_UDP_SUPPORT:-false}"

    require_value "RESIDENTIAL_PROXY_TYPE" "${RESIDENTIAL_PROXY_TYPE:-}"
    require_value "RESIDENTIAL_PROXY_HOST" "${RESIDENTIAL_PROXY_HOST:-}"
    require_value "RESIDENTIAL_PROXY_PORT" "${RESIDENTIAL_PROXY_PORT:-}"
    require_not_placeholder "RESIDENTIAL_PROXY_HOST" "${RESIDENTIAL_PROXY_HOST:-}"
    require_not_placeholder "RESIDENTIAL_PROXY_PORT" "${RESIDENTIAL_PROXY_PORT:-}"
    require_port "RESIDENTIAL_PROXY_PORT" "${RESIDENTIAL_PROXY_PORT:-}"
    require_port "RESIDENTIAL_PROXY_LOCAL_PORT" "${RESIDENTIAL_PROXY_LOCAL_PORT:-12345}"
    require_port "RESIDENTIAL_PROXY_UDP_LOCAL_PORT" "${RESIDENTIAL_PROXY_UDP_LOCAL_PORT:-12346}"

    case "${RESIDENTIAL_PROXY_TYPE}" in
        socks5|http-connect)
            ;;
        *)
            fail "RESIDENTIAL_PROXY_TYPE must be socks5 or http-connect"
            ;;
    esac

    if [[ -n "${RESIDENTIAL_PROXY_USERNAME:-}" ]]; then
        require_not_placeholder "RESIDENTIAL_PROXY_USERNAME" "${RESIDENTIAL_PROXY_USERNAME:-}"
    fi

    if [[ -n "${RESIDENTIAL_PROXY_PASSWORD:-}" ]]; then
        require_not_placeholder "RESIDENTIAL_PROXY_PASSWORD" "${RESIDENTIAL_PROXY_PASSWORD:-}"
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT:-false}" == "true" && "${RESIDENTIAL_PROXY_TYPE}" != "socks5" ]]; then
        fail "ENABLE_SOCKS5_UDP_SUPPORT=true requires RESIDENTIAL_PROXY_TYPE=socks5"
    fi

    if [[ "${ENABLE_SOCKS5_UDP_SUPPORT:-false}" == "true" ]]; then
        require_equals "ENABLE_UDP_RELAY" "${ENABLE_UDP_RELAY:-}" "true"
    else
        require_equals "ENABLE_UDP_RELAY" "${ENABLE_UDP_RELAY:-}" "false"
    fi

    validate_peer_definitions
}

main() {
    parse_args "$@"

    load_env_file "${PREFLIGHT_FILE}"
    validate_preflight

    load_env_file "${USER_DATA_FILE}"
    validate_user_data_values

    echo "Residential-proxy cutover inputs are internally consistent."
    echo "Primary test peer: ${PRIMARY_TEST_PEER_NAME}"
    if [[ -n "${SECONDARY_TEST_PEER_NAME:-}" ]]; then
        echo "Secondary test peer: ${SECONDARY_TEST_PEER_NAME}"
    fi
    echo "Residential proxy host: ${RESIDENTIAL_PROXY_HOST}"
    echo "Residential proxy type: ${RESIDENTIAL_PROXY_TYPE}"
}

main "$@"