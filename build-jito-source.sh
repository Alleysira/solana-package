#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

source_dir="${JITO_SOURCE:-../jito-solana}"
image="${JITO_IMAGE:-solana-diff/jito-solana:4.3.0-jito-arm64}"
floor_gib="${BUILD_DISK_FLOOR_GIB:-3}"
jobs="${BUILD_JOBS:-2}"
for value in "$floor_gib" "$jobs"; do
  if [[ ! "$value" =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "Disk floor and build jobs must be positive integers." >&2
    exit 1
  fi
done

free_kib() { df -Pk . | awk 'NR==2 {print $4}'; }
if (( $(free_kib) < (floor_gib + 4) * 1024 * 1024 )); then
  echo "Need at least $((floor_gib + 4)) GiB free to attempt this cached source build." >&2
  exit 1
fi
test "$(git -C "$source_dir" rev-parse HEAD)" = 07270be44c712356d8fb94dff8e7a1edd425dbff
if [[ -n "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
  echo "Jito source has tracked modifications; refusing an unrecorded source build." >&2
  exit 1
fi

build_args=(--platform linux/arm64 --load --progress plain)
if [[ -n "${BUILD_CA_PEM:-}" ]]; then
  build_args+=(--secret id=build_ca,env=BUILD_CA_PEM)
fi
docker buildx build "${build_args[@]}" \
  --build-context "jito_source=$source_dir" --build-arg "BUILD_JOBS=$jobs" \
  --file Dockerfile.jito-source --tag "$image" . &
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
    echo "Disk safety floor reached: ${remaining} KiB free. Cancelling build, retaining its cache." >&2
    exit 2
  fi
  sleep 5
done
wait "$build_pid"
trap - EXIT

docker run --rm --platform linux/arm64 "$image" agave-validator --version
