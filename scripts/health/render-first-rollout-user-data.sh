#!/usr/bin/env bash

set -euo pipefail

TMP_OVERRIDES_FILE=""
MAX_USER_DATA_BYTES=16384

usage() {
    cat <<'EOF'
Usage:
  bash scripts/health/render-first-rollout-user-data.sh \
    --preflight PATH_TO_PREFLIGHT_ENV \
    --user-data PATH_TO_USER_DATA_ENV \
    --output PATH_TO_RENDERED_USER_DATA

Options:
    --validation-mode first-rollout|proxy-cutover|none Optional. Defaults to first-rollout
    --mode launcher|full        Optional. Defaults to launcher
    --template PATH_TO_TEMPLATE Optional. Used in full mode. Defaults to scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh

Notes:
  - this helper validates the inputs first
    - launcher mode is intended for the first direct-only rollout and avoids the 16 KB EC2 user-data limit
EOF
}

fail() {
    echo "Render failed: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_OVERRIDES_FILE:-}" && -f "${TMP_OVERRIDES_FILE}" ]]; then
        rm -f "${TMP_OVERRIDES_FILE}"
    fi
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

parse_args() {
    PREFLIGHT_FILE=""
    USER_DATA_FILE=""
    OUTPUT_FILE=""
    TEMPLATE_FILE=""
    RENDER_MODE="launcher"
    VALIDATION_MODE="first-rollout"

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
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --validation-mode)
                VALIDATION_MODE="$2"
                shift 2
                ;;
            --mode)
                RENDER_MODE="$2"
                shift 2
                ;;
            --template)
                TEMPLATE_FILE="$2"
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
    require_value "OUTPUT_FILE" "${OUTPUT_FILE}"

    case "${RENDER_MODE}" in
        launcher|full)
            ;;
        *)
            fail "--mode must be launcher or full"
            ;;
    esac

    case "${VALIDATION_MODE}" in
        first-rollout|proxy-cutover|none)
            ;;
        *)
            fail "--validation-mode must be first-rollout, proxy-cutover, or none"
            ;;
    esac
}

load_env_file() {
    local path

    path="$1"
    require_file "${path}"
    # shellcheck disable=SC1090
    source "${path}"
}

extract_primary_peer_values() {
    local entry
    local peer_name
    local peer_public_key
    local peer_address
    local peer_dns
    local entries

    PRIMARY_PEER_PUBLIC_KEY=""
    PRIMARY_PEER_ADDRESS=""
    PRIMARY_PEER_DNS=""

    IFS=';' read -r -a entries <<< "${PEER_DEFINITIONS}"

    for entry in "${entries[@]}"; do
        [[ -z "${entry}" ]] && continue
        IFS='|' read -r peer_name peer_public_key peer_address peer_dns <<< "${entry}"

        if [[ "${peer_name}" == "${PRIMARY_CLIENT_NAME}" ]]; then
            PRIMARY_PEER_PUBLIC_KEY="${peer_public_key}"
            PRIMARY_PEER_ADDRESS="${peer_address}"
            PRIMARY_PEER_DNS="${peer_dns}"
            break
        fi
    done

    require_value "PRIMARY_PEER_PUBLIC_KEY" "${PRIMARY_PEER_PUBLIC_KEY}"
    require_value "PRIMARY_PEER_ADDRESS" "${PRIMARY_PEER_ADDRESS}"
    require_value "PRIMARY_PEER_DNS" "${PRIMARY_PEER_DNS}"
}

build_overrides_file() {
    local overrides_file

    overrides_file="$1"

    cat > "${overrides_file}" <<EOF
CLIENT_ADDRESS_CIDR	${PRIMARY_PEER_ADDRESS}
CLIENT_DNS	${PRIMARY_PEER_DNS}
CLIENT_PUBLIC_KEY	${PRIMARY_PEER_PUBLIC_KEY}
PRIMARY_CLIENT_NAME	${PRIMARY_CLIENT_NAME}
PEER_DEFINITIONS	${PEER_DEFINITIONS}
EGRESS_MODE	${EGRESS_MODE}
RESIDENTIAL_PROXY_TYPE	${RESIDENTIAL_PROXY_TYPE:-socks5}
RESIDENTIAL_PROXY_HOST	${RESIDENTIAL_PROXY_HOST:-}
RESIDENTIAL_PROXY_PORT	${RESIDENTIAL_PROXY_PORT:-}
RESIDENTIAL_PROXY_USERNAME	${RESIDENTIAL_PROXY_USERNAME:-}
RESIDENTIAL_PROXY_PASSWORD	${RESIDENTIAL_PROXY_PASSWORD:-}
ENABLE_SOCKS5_UDP_SUPPORT	${ENABLE_SOCKS5_UDP_SUPPORT}
ENABLE_AWS_CONSOLE_EGRESS_SWITCH	${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}
EOF
}

render_full_template() {
    local template_file
    local overrides_file
    local output_file

    template_file="$1"
    overrides_file="$2"
    output_file="$3"

    awk -F '\t' '
        FNR == NR {
            overrides[$1] = $2
            next
        }

        /^[A-Z0-9_]+=".*"$/ {
            split($0, parts, "=")
            key = parts[1]

            if (key in overrides) {
                value = overrides[key]
                gsub(/\\/, "\\\\", value)
                gsub(/"/, "\\\"", value)
                print key "=\"" value "\""
                next
            }
        }

        { print }
    ' "${overrides_file}" "${template_file}" > "${output_file}"
}

escape_for_double_quotes() {
    local value

    value="$1"
    value="${value//\\/\\\\}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    value="${value//\"/\\\"}"
    printf '%s' "${value}"
}

compute_archive_url() {
    if [[ -n "${DEPLOYMENT_SOURCE_URL:-}" ]]; then
        printf '%s' "${DEPLOYMENT_SOURCE_URL}"
        return
    fi

    printf 'https://github.com/%s/%s/archive/refs/heads/%s.tar.gz' \
        "${TARGET_GITHUB_OWNER}" \
        "${TARGET_GITHUB_REPO}" \
        "${TARGET_GITHUB_BRANCH}"
}

render_launcher() {
    local output_file
    local archive_url

    output_file="$1"
    archive_url="$(compute_archive_url)"

    cat > "${output_file}" <<EOF
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

BOOTSTRAP_ARCHIVE_URL="$(escape_for_double_quotes "${archive_url}")"
BOOTSTRAP_WORKDIR="/opt/wireguard-bootstrap"
BOOTSTRAP_ARCHIVE_FILE="\${BOOTSTRAP_WORKDIR}/source.tar.gz"
BOOTSTRAP_SRC_DIR="\${BOOTSTRAP_WORKDIR}/src"

PRIMARY_CLIENT_NAME="$(escape_for_double_quotes "${PRIMARY_CLIENT_NAME}")"
PEER_DEFINITIONS="$(escape_for_double_quotes "${PEER_DEFINITIONS}")"
EGRESS_MODE="$(escape_for_double_quotes "${EGRESS_MODE}")"
RESIDENTIAL_PROXY_TYPE="$(escape_for_double_quotes "${RESIDENTIAL_PROXY_TYPE:-socks5}")"
ENABLE_SOCKS5_UDP_SUPPORT="$(escape_for_double_quotes "${ENABLE_SOCKS5_UDP_SUPPORT}")"
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="$(escape_for_double_quotes "${ENABLE_AWS_CONSOLE_EGRESS_SWITCH}")"
RESIDENTIAL_PROXY_HOST="$(escape_for_double_quotes "${RESIDENTIAL_PROXY_HOST:-}")"
RESIDENTIAL_PROXY_PORT="$(escape_for_double_quotes "${RESIDENTIAL_PROXY_PORT:-}")"
RESIDENTIAL_PROXY_USERNAME="$(escape_for_double_quotes "${RESIDENTIAL_PROXY_USERNAME:-}")"
RESIDENTIAL_PROXY_PASSWORD="$(escape_for_double_quotes "${RESIDENTIAL_PROXY_PASSWORD:-}")"

apt-get update
apt-get install -y ca-certificates curl tar

install -d -m 755 "\${BOOTSTRAP_WORKDIR}" "\${BOOTSTRAP_SRC_DIR}"
curl -fsSL "\${BOOTSTRAP_ARCHIVE_URL}" -o "\${BOOTSTRAP_ARCHIVE_FILE}"
tar -xzf "\${BOOTSTRAP_ARCHIVE_FILE}" -C "\${BOOTSTRAP_SRC_DIR}"

BOOTSTRAP_REPO_DIR="\$(find "\${BOOTSTRAP_SRC_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "\${BOOTSTRAP_REPO_DIR}" ]]; then
    echo "Unable to locate extracted repository directory." >&2
    exit 1
fi

export PRIMARY_CLIENT_NAME
export PEER_DEFINITIONS
export EGRESS_MODE
export RESIDENTIAL_PROXY_TYPE
export ENABLE_SOCKS5_UDP_SUPPORT
export ENABLE_AWS_CONSOLE_EGRESS_SWITCH
export RESIDENTIAL_PROXY_HOST
export RESIDENTIAL_PROXY_PORT
export RESIDENTIAL_PROXY_USERNAME
export RESIDENTIAL_PROXY_PASSWORD

bash "\${BOOTSTRAP_REPO_DIR}/scripts/bootstrap/bootstrap-wireguard-ec2.sh"
EOF
}

check_output_size() {
    local output_file
    local size_bytes

    output_file="$1"
    size_bytes="$(wc -c < "${output_file}")"

    if (( size_bytes > MAX_USER_DATA_BYTES )); then
        fail "rendered user-data is ${size_bytes} bytes; EC2 user-data limit is ${MAX_USER_DATA_BYTES} bytes"
    fi

    echo "Rendered user-data size: ${size_bytes} bytes"
}

main() {
    local script_dir
    local repo_root
    local validator_script
    local overrides_file

    parse_args "$@"

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "${script_dir}/../.." && pwd)"
    validator_script=""

    if [[ -z "${TEMPLATE_FILE}" ]]; then
        TEMPLATE_FILE="${repo_root}/scripts/bootstrap/ec2-user-data-wireguard-bootstrap.sh"
    fi

    require_file "${TEMPLATE_FILE}"

    case "${VALIDATION_MODE}" in
        first-rollout)
            validator_script="${script_dir}/validate-first-rollout-inputs.sh"
            ;;
        proxy-cutover)
            validator_script="${script_dir}/validate-residential-proxy-cutover-inputs.sh"
            ;;
    esac

    if [[ -n "${validator_script}" ]]; then
        require_file "${validator_script}"
        bash "${validator_script}" --preflight "${PREFLIGHT_FILE}" --user-data "${USER_DATA_FILE}" >/dev/null
    fi

    load_env_file "${PREFLIGHT_FILE}"
    load_env_file "${USER_DATA_FILE}"
    extract_primary_peer_values

    install -d -m 755 "$(dirname "${OUTPUT_FILE}")"

    if [[ "${RENDER_MODE}" == "full" ]]; then
        TMP_OVERRIDES_FILE="$(mktemp)"
        trap cleanup EXIT
        overrides_file="${TMP_OVERRIDES_FILE}"
        build_overrides_file "${overrides_file}"
        render_full_template "${TEMPLATE_FILE}" "${overrides_file}" "${OUTPUT_FILE}"
    else
        render_launcher "${OUTPUT_FILE}"
    fi

    check_output_size "${OUTPUT_FILE}"

    echo "Rendered user-data file: ${OUTPUT_FILE}"
    echo "Primary client: ${PRIMARY_CLIENT_NAME} (${PRIMARY_PEER_ADDRESS})"
    echo "Render mode: ${RENDER_MODE}"
    echo "Validation mode: ${VALIDATION_MODE}"
    if [[ "${RENDER_MODE}" == "full" ]]; then
        echo "Template source: ${TEMPLATE_FILE}"
    else
        echo "Archive source: $(compute_archive_url)"
    fi
}

main "$@"