#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d)"

cleanup() {
    rm -rf "${work_dir}"
}

trap cleanup EXIT

cd "${repo_root}"

preflight_template="config/examples/deployment-preflight.first-rollout.example.env"
user_data_template="config/examples/user-data.first-rollout.example.env"
preflight_file="${work_dir}/deployment-preflight.local.env"
user_data_file="${work_dir}/user-data.local.env"
output_file="${work_dir}/ec2-user-data-first-rollout.sh"
proxy_preflight_file="${work_dir}/proxy-cutover-preflight.local.env"
proxy_user_data_file="${work_dir}/proxy-cutover-user-data.local.env"
proxy_output_file="${work_dir}/ec2-user-data-proxy-cutover.sh"

cp "${preflight_template}" "${preflight_file}"
cp "${user_data_template}" "${user_data_file}"
cp "${preflight_template}" "${proxy_preflight_file}"
cp "${user_data_template}" "${proxy_user_data_file}"

python3 - <<'PY' "${preflight_file}" "${user_data_file}"
from pathlib import Path
import sys

preflight_path = Path(sys.argv[1])
user_data_path = Path(sys.argv[2])

preflight_text = preflight_path.read_text()
preflight_replacements = {
    'TARGET_AWS_ACCOUNT_NAME="REPLACE_WITH_TARGET_AWS_ACCOUNT_NAME"': 'TARGET_AWS_ACCOUNT_NAME="sandbox-account"',
    'TARGET_AWS_ACCOUNT_ID="REPLACE_WITH_TARGET_AWS_ACCOUNT_ID"': 'TARGET_AWS_ACCOUNT_ID="123456789012"',
    'TARGET_GITHUB_OWNER="REPLACE_WITH_TARGET_GITHUB_OWNER"': 'TARGET_GITHUB_OWNER="example-owner"',
    'TARGET_GITHUB_REPO="REPLACE_WITH_TARGET_GITHUB_REPO"': 'TARGET_GITHUB_REPO="wireguard-vpn"',
}
for old, new in preflight_replacements.items():
    preflight_text = preflight_text.replace(old, new)
preflight_path.write_text(preflight_text)

user_data_text = user_data_path.read_text()
user_data_replacements = {
    'REPLACE_WITH_PHONE_TEST_PUBLIC_KEY': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    'REPLACE_WITH_CLOUD_TEST_PUBLIC_KEY': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
}
for old, new in user_data_replacements.items():
    user_data_text = user_data_text.replace(old, new)
user_data_path.write_text(user_data_text)
PY

python3 - <<'PY' "${proxy_preflight_file}" "${proxy_user_data_file}"
from pathlib import Path
import sys

preflight_path = Path(sys.argv[1])
user_data_path = Path(sys.argv[2])

preflight_text = preflight_path.read_text()
preflight_replacements = {
    'TARGET_AWS_ACCOUNT_NAME="REPLACE_WITH_TARGET_AWS_ACCOUNT_NAME"': 'TARGET_AWS_ACCOUNT_NAME="sandbox-account"',
    'TARGET_AWS_ACCOUNT_ID="REPLACE_WITH_TARGET_AWS_ACCOUNT_ID"': 'TARGET_AWS_ACCOUNT_ID="123456789012"',
    'TARGET_GITHUB_OWNER="REPLACE_WITH_TARGET_GITHUB_OWNER"': 'TARGET_GITHUB_OWNER="example-owner"',
    'TARGET_GITHUB_REPO="REPLACE_WITH_TARGET_GITHUB_REPO"': 'TARGET_GITHUB_REPO="wireguard-vpn"',
    'ENABLE_RESIDENTIAL_PROXY="false"': 'ENABLE_RESIDENTIAL_PROXY="true"',
}
for old, new in preflight_replacements.items():
    preflight_text = preflight_text.replace(old, new)
preflight_path.write_text(preflight_text)

user_data_text = user_data_path.read_text()
user_data_replacements = {
    'REPLACE_WITH_PHONE_TEST_PUBLIC_KEY': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    'REPLACE_WITH_CLOUD_TEST_PUBLIC_KEY': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
    'EGRESS_MODE="direct"': 'EGRESS_MODE="residential-proxy"',
    'RESIDENTIAL_PROXY_HOST=""': 'RESIDENTIAL_PROXY_HOST="proxy.example.net"',
    'RESIDENTIAL_PROXY_PORT=""': 'RESIDENTIAL_PROXY_PORT="12345"',
    'RESIDENTIAL_PROXY_USERNAME=""': 'RESIDENTIAL_PROXY_USERNAME="proxy-user"',
    'RESIDENTIAL_PROXY_PASSWORD=""': 'RESIDENTIAL_PROXY_PASSWORD="proxy-pass"',
}
for old, new in user_data_replacements.items():
    user_data_text = user_data_text.replace(old, new)
user_data_path.write_text(user_data_text)
PY

echo "Validating sanitized first-rollout examples"
bash scripts/health/validate-first-rollout-inputs.sh \
    --preflight "${preflight_file}" \
    --user-data "${user_data_file}"

echo "Rendering first-rollout launcher from sanitized examples"
bash scripts/health/render-first-rollout-user-data.sh \
    --preflight "${preflight_file}" \
    --user-data "${user_data_file}" \
    --output "${output_file}"

grep -F 'BOOTSTRAP_ARCHIVE_URL="https://github.com/example-owner/wireguard-vpn/archive/refs/heads/main.tar.gz"' "${output_file}" >/dev/null
grep -F 'PRIMARY_CLIENT_NAME="phone-test-1"' "${output_file}" >/dev/null
grep -F 'EGRESS_MODE="direct"' "${output_file}" >/dev/null
grep -F 'ENABLE_AWS_CONSOLE_EGRESS_SWITCH="false"' "${output_file}" >/dev/null
grep -F "bash \"\${BOOTSTRAP_REPO_DIR}/scripts/bootstrap/bootstrap-wireguard-ec2.sh\"" "${output_file}" >/dev/null

echo "Validating sanitized proxy-cutover examples"
bash scripts/health/validate-residential-proxy-cutover-inputs.sh \
    --preflight "${proxy_preflight_file}" \
    --user-data "${proxy_user_data_file}"

echo "Rendering proxy-cutover launcher from sanitized examples"
bash scripts/health/render-first-rollout-user-data.sh \
    --validation-mode proxy-cutover \
    --preflight "${proxy_preflight_file}" \
    --user-data "${proxy_user_data_file}" \
    --output "${proxy_output_file}"

grep -F 'EGRESS_MODE="residential-proxy"' "${proxy_output_file}" >/dev/null
grep -F 'RESIDENTIAL_PROXY_HOST="proxy.example.net"' "${proxy_output_file}" >/dev/null
grep -F 'RESIDENTIAL_PROXY_PORT="12345"' "${proxy_output_file}" >/dev/null

echo "Sanitized first-rollout examples validated and rendered successfully"