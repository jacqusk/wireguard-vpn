#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

WG_INTERFACE="wg0"
WG_PORT="51820"
WG_TUNNEL_MTU="1380"
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
RESIDENTIAL_DNS_UPSTREAM_IP="54.72.70.84"
ENABLE_SOCKS5_UDP_SUPPORT="false"
RESIDENTIAL_PROXY_UDP_LOCAL_PORT="12346"
ENABLE_AWS_CONSOLE_EGRESS_SWITCH="false"
AWS_EGRESS_TAG_KEY="wireguard-egress-mode"
AWS_EGRESS_SYNC_INTERVAL_SECONDS="30"
DEPLOYMENT_SOURCE_URL=""
TARGET_GITHUB_OWNER="jacqusk"
TARGET_GITHUB_REPO="wireguard-vpn"
TARGET_GITHUB_BRANCH="main"

BOOTSTRAP_WORKDIR="/opt/wireguard-bootstrap"
BOOTSTRAP_ARCHIVE_FILE="${BOOTSTRAP_WORKDIR}/source.tar.gz"
BOOTSTRAP_SRC_DIR="${BOOTSTRAP_WORKDIR}/src"

log() {
    echo "[wireguard-user-data] $*"
}

compute_archive_url() {
    if [[ -n "${DEPLOYMENT_SOURCE_URL}" ]]; then
        printf '%s' "${DEPLOYMENT_SOURCE_URL}"
        return
    fi

    printf 'https://github.com/%s/%s/archive/refs/heads/%s.tar.gz' \
        "${TARGET_GITHUB_OWNER}" \
        "${TARGET_GITHUB_REPO}" \
        "${TARGET_GITHUB_BRANCH}"
}

main() {
    local archive_url
    local bootstrap_repo_dir

    archive_url="$(compute_archive_url)"

    log "Preparing bootstrap launcher"
    apt-get update
    apt-get install -y ca-certificates curl tar

    rm -rf "${BOOTSTRAP_WORKDIR}"
    install -d -m 755 "${BOOTSTRAP_WORKDIR}" "${BOOTSTRAP_SRC_DIR}"

    log "Downloading bootstrap source archive"
    curl -fsSL "${archive_url}" -o "${BOOTSTRAP_ARCHIVE_FILE}"
    tar -xzf "${BOOTSTRAP_ARCHIVE_FILE}" -C "${BOOTSTRAP_SRC_DIR}"

    bootstrap_repo_dir="$(find "${BOOTSTRAP_SRC_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [[ -z "${bootstrap_repo_dir}" ]]; then
        echo "Unable to locate extracted repository directory." >&2
        exit 1
    fi

    export WG_INTERFACE
    export WG_PORT
    export WG_TUNNEL_MTU
    export WG_NETWORK_CIDR
    export SERVER_ADDRESS_CIDR
    export CLIENT_ADDRESS_CIDR
    export CLIENT_DNS
    export CLIENT_PUBLIC_KEY
    export PRIMARY_CLIENT_NAME
    export PEER_DEFINITIONS
    export ENABLE_SHARED_PROFILE
    export SHARED_CLIENT_NAME
    export SHARED_CLIENT_PUBLIC_KEY
    export SHARED_CLIENT_ADDRESS_CIDR
    export SHARED_CLIENT_DNS
    export ALLOW_SSH_CIDR
    export EGRESS_MODE
    export RESIDENTIAL_PROXY_TYPE
    export RESIDENTIAL_PROXY_HOST
    export RESIDENTIAL_PROXY_PORT
    export RESIDENTIAL_PROXY_USERNAME
    export RESIDENTIAL_PROXY_PASSWORD
    export RESIDENTIAL_PROXY_LOCAL_PORT
    export RESIDENTIAL_DNS_UPSTREAM_IP
    export ENABLE_SOCKS5_UDP_SUPPORT
    export RESIDENTIAL_PROXY_UDP_LOCAL_PORT
    export ENABLE_AWS_CONSOLE_EGRESS_SWITCH
    export AWS_EGRESS_TAG_KEY
    export AWS_EGRESS_SYNC_INTERVAL_SECONDS

    log "Running main bootstrap"
    bash "${bootstrap_repo_dir}/scripts/bootstrap/bootstrap-wireguard-ec2.sh"
}

main "$@"
