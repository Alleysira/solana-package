#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

for command in docker kurtosis; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Missing command: %s\n' "$command" >&2
        exit 1
    fi
done

# On this Mac, the workspace and OrbStack disk share the APFS data volume.
# This is a safety margin, not a measured minimum for Solana.
minimum_gib=${MIN_FREE_GIB:-15}
if [[ ! "$minimum_gib" =~ ^[1-9][0-9]{0,3}$ ]]; then
    printf 'MIN_FREE_GIB must be an integer from 1 to 9999.\n' >&2
    exit 1
fi
available_kib=$(df -Pk . | awk 'NR == 2 { print $4 }')
if [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
    printf 'Cannot determine available disk space. Deployment not started.\n' >&2
    exit 1
fi
if (( available_kib < minimum_gib * 1024 * 1024 )); then
    printf 'Deployment not started: %s KiB free; reserve at least %s GiB.\n' "$available_kib" "$minimum_gib" >&2
    printf 'See LOCAL.md. No images, containers, or volumes were deleted.\n' >&2
    exit 1
fi

docker info --format 'Docker: {{.OSType}}/{{.Architecture}}, CPUs={{.NCPU}}, RAM={{.MemTotal}} bytes'
exec kurtosis run --enclave solana-local --args-file local-params.yaml .
