#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

image="${JITO_IMAGE:-solana-diff/jito-solana:4.3.0-jito-amd64}"
floor_gib="${BUILD_DISK_FLOOR_GIB:-3}"
if [[ ! "$floor_gib" =~ ^[1-9][0-9]{0,3}$ ]]; then
  echo "BUILD_DISK_FLOOR_GIB must be a positive integer." >&2
  exit 1
fi

free_kib() { df -Pk . | awk 'NR==2 {print $4}'; }
if (( $(free_kib) < (floor_gib + 1) * 1024 * 1024 )); then
  echo "Need at least $((floor_gib + 1)) GiB free to build the Jito runtime image." >&2
  exit 1
fi

build_args=(--platform linux/amd64 --load --progress plain)
if [[ -n "${BUILD_CA_PEM:-}" ]]; then
  build_args+=(--secret id=build_ca,env=BUILD_CA_PEM)
fi
docker buildx build "${build_args[@]}" \
  --file Dockerfile.jito --tag "$image" . &
build_pid=$!
cancel() {
  kill -TERM "$build_pid" 2>/dev/null || true
  wait "$build_pid" 2>/dev/null || true
}
trap cancel EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
while kill -0 "$build_pid" 2>/dev/null; do
  remaining=$(free_kib)
  if (( remaining < floor_gib * 1024 * 1024 )); then
    echo "Disk safety floor reached: ${remaining} KiB free. Cancelling build." >&2
    exit 2
  fi
  sleep 5
done
wait "$build_pid"
trap - EXIT

docker run --rm --platform linux/amd64 "$image" agave-validator --version
