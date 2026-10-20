#!/usr/bin/env bash
# build-firedancer.sh — build the Frankendancer (fdctl + solana) container image.
#
# Records the source pin honestly before building:
#   - the firedancer submodule must be at the pinned fork commit ff881b69
#   - the Agave submodule inside it must be at the pinned commit 535ec972
#   - any tracked modification is rejected (the fork commit carries the fixes)
#
# On this Mac Studio the build runs under OrbStack's amd64 emulation (Rosetta)
# via `docker --context orbstack --platform linux/amd64`.  The image is build
# evidence only; the validator cannot start here (NUMA/hugepage gate).
set -euo pipefail
cd "$(dirname "$0")"

source_dir="${FIREDANCER_SOURCE:-../firedancer}"
image="${FIREDANCER_IMAGE:-solana-diff/firedancer:v26.09.4-frankendancer-amd64}"
floor_gib="${BUILD_DISK_FLOOR_GIB:-8}"
jobs="${BUILD_JOBS:-4}"

expected_commit="ff881b69a93a6519c1a6f09698aaf208753a0a8f"
expected_agave="535ec972e6f0037b6a4c5a5e98cff4597781e678"

for value in "$floor_gib" "$jobs"; do
  if [[ ! "$value" =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "Disk floor and build jobs must be positive integers." >&2
    exit 1
  fi
done

free_kib() { df -Pk . | awk 'NR==2 {print $4}'; }
if (( $(free_kib) < (floor_gib + 2) * 1024 * 1024 )); then
  echo "Need at least $((floor_gib + 2)) GiB free to attempt this build." >&2
  exit 1
fi

# Honest source pin verification.  The fork commit carries the tracked
# conversion fixes and NUMA fallback; a dirty working tree would hide work.
# Note: submodules have a .git *file* (gitdir pointer), not a .git directory,
# so use `git rev-parse` rather than a -d check on .git.
if ! actual_commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)"; then
  echo "Source dir $source_dir is not a git checkout." >&2
  exit 1
fi
if [[ "$actual_commit" != "$expected_commit" ]]; then
  echo "Firedancer submodule is at $actual_commit, expected $expected_commit." >&2
  echo "The fork commit ff881b69 carries the tracked GCC-12 + NUMA-fallback fixes." >&2
  exit 1
fi
if [[ -n "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
  echo "Firedancer source has tracked modifications; refusing an unrecorded source build." >&2
  exit 1
fi
actual_agave="$(git -C "$source_dir/agave" rev-parse HEAD 2>/dev/null || true)"
if [[ "$actual_agave" != "$expected_agave" ]]; then
  echo "Agave submodule is at ${actual_agave:-<missing>}, expected $expected_agave." >&2
  exit 1
fi

echo "[build-firedancer] source OK: firedancer=$actual_commit agave=$actual_agave"
echo "[build-firedancer] image: $image  platform: linux/amd64 (Rosetta)"

docker_context="${DOCKER_CONTEXT:-orbstack}"
# OrbStack's docker CLI ships a buildx plugin at
# /Applications/OrbStack.app/Contents/MacOS/xbin/docker-buildx; register it
# once via: ln -sf <that> ~/.docker/cli-plugins/docker-buildx
# Plain `docker build --platform` does NOT cross-build on OrbStack (it runs
# RUN steps natively as arm64); buildx with --builder orbstack does, via
# Rosetta, producing a real linux/amd64 image.
build_args=(
  --context "$docker_context"
  buildx build
  --builder "$docker_context"
  --platform linux/amd64
  --load
  --progress plain
  --build-arg "FIREDANCER_COMMIT=$expected_commit"
  --build-arg "AGAVE_SUBMODULE_COMMIT=$expected_agave"
  --build-arg "BUILD_JOBS=$jobs"
  --file Dockerfile.firedancer
  --tag "$image"
  .
)
# NOTE: the Dockerfile clones the fork at FIREDANCER_COMMIT (not COPY from a
# build-context), because the submodule .git is a gitdir pointer whose object
# database lives outside the copied subtree.  The local submodule pin is still
# verified above as a fail-fast provenance gate.

docker "${build_args[@]}" &
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
    echo "Disk safety floor reached: ${remaining} KiB free. Cancelling build, retaining cache." >&2
    exit 2
  fi
  # Also watch available memory; Rosetta builds are memory-heavy.  Stop early
  # if the host is under pressure (the goal: stop the service early and report).
  avail_mib=$(vm_stat | awk -v ps=16384 'NR>1{f+=$3}END{printf "%.0f", f*ps/1048576}')
  if [[ "$avail_mib" =~ ^[0-9]+$ ]] && (( avail_mib < 4096 )); then
    echo "Memory pressure: ~${avail_mib} MiB inactive. Cancelling build early." >&2
    exit 2
  fi
  sleep 10
done
wait "$build_pid"
trap - EXIT

# Build-evidence check: print versions from the image.  The validator cannot
# start on this host (NUMA gate), so we verify the artifacts, not a run.
docker --context "$docker_context" run --rm --platform linux/amd64 "$image" version
