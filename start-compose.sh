#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

minimum_gib=${MIN_FREE_GIB:-8}
if [[ ! "$minimum_gib" =~ ^[1-9][0-9]{0,3}$ ]]; then
  echo "MIN_FREE_GIB must be an integer from 1 to 9999." >&2
  exit 1
fi
available_kib=$(df -Pk . | awk 'NR == 2 { print $4 }')
if [[ ! "$available_kib" =~ ^[0-9]+$ ]] || (( available_kib < minimum_gib * 1024 * 1024 )); then
  echo "Deployment not started: reserve at least ${minimum_gib} GiB free." >&2
  exit 1
fi
docker compose -f compose.agave.yaml config --quiet
for image in \
  solana-diff/agave:4.3.0-arm64 \
  tiljordan/solana-explorer:1.0.6@sha256:91ab7d1a7a24101f3950e027c97bbec9c093e4059a68cba49a923d8876e996b8; do
  docker image inspect "$image" >/dev/null
done
exec docker compose -f compose.agave.yaml up -d --pull never --wait --wait-timeout 180
