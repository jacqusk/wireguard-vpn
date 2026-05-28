#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "${repo_root}"

shell_files=()
while IFS= read -r -d '' file; do
    shell_files+=("${file}")
done < <(find scripts tests -type f -name '*.sh' -print0)

if [[ "${#shell_files[@]}" -eq 0 ]]; then
    echo "No shell files found."
    exit 0
fi

echo "Validating bash syntax for ${#shell_files[@]} files"
for file in "${shell_files[@]}"; do
    bash -n "${file}"
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "Running shellcheck"
    shellcheck "${shell_files[@]}"
else
    echo "shellcheck not found; skipping lint"
fi