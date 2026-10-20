#!/usr/bin/env bash
# build-sig.sh — build the SIG v2 (Zig) observer container image.
#
# Records the source pin honestly before building:
#   - the sig submodule must be at the pinned fork commit 0c1e96c1
#     (main branch; upstream base b5026c60 byte-identical to
#     upstream Syndica/sig main)
#   - the branch INTENTIONALLY carries 5 tracked deviation files + DEVIATIONS.md
#     (the development observer path) on top of that base; a clean-tree check
#     would be wrong here.
#   - we verify the deviation fileset (diff vs the upstream-identical base
#     b5026c60) matches the expected list, and that the base is an ancestor.
#
# On this Mac Studio the build runs under OrbStack's amd64 emulation (Rosetta)
# via `docker --context orbstack --platform linux/amd64`.  The image is build
# evidence only; SIG is a non-voting observer and requires an external cluster
# (leader schedule + snapshot + shred stream) to start — none of which exist on
# this host without a running testnet.  Honest ceiling here: `built`.
set -euo pipefail
cd "$(dirname "$0")"

source_dir="${SIG_SOURCE:-../sig}"
floor_gib="${BUILD_DISK_FLOOR_GIB:-8}"
jobs="${BUILD_JOBS:-4}"

# Build target.  Two supported values (see Dockerfile.sig BUILD TARGET note):
#   x86_64  (DEFAULT) — -Dtarget=x86_64-linux-gnu.2.36, runtime linux/amd64 (Rosetta).
#                        CI-matching.  Honest ceiling on this Mac: `built`
#                        (OrbStack's Rosetta amd64 syscall translation does NOT
#                        translate io_uring_setup → ENOSYS even under --privileged,
#                        so accounts_db crashes at init with SystemOutdated).
#   arm64            — -Dtarget=aarch64-linux-gnu.2.36, runtime linux/arm64 (native).
#                        Runtime-capable: io_uring_setup is only blocked by the
#                        default container seccomp profile (EPERM), cleared by
#                        --privileged.  Under --privileged ALL services boot
#                        (gossip starts, accounts_db starts past io_uring).
#                        Honest ceiling on this Mac: `started`.  arm64 is a
#                        recorded target-architecture deviation from CI's x86_64,
#                        NOT a source deviation.
sig_target="${SIG_TARGET:-x86_64}"
case "$sig_target" in
  x86_64)
    zig_target="x86_64-linux-gnu.2.36"
    runtime_platform="linux/amd64"
    image="${SIG_IMAGE:-solana-diff/sig:v0.2.0-amd64}"
    ;;
  arm64)
    zig_target="aarch64-linux-gnu.2.36"
    runtime_platform="linux/arm64"
    image="${SIG_IMAGE:-solana-diff/sig:v0.2.0-arm64-functional}"
    ;;
  *)
    echo "SIG_TARGET must be x86_64 or arm64 (got '$sig_target')." >&2
    exit 1
    ;;
esac

expected_commit="0c1e96c1ef335ecf9f62e337477faf5bdab0d83a"

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

# Honest source pin verification.  The Alleysira/sig fork is on the
# `main` branch.  Its upstream base b5026c60 is byte-identical to
# upstream Syndica/sig main; the branch carries 5 tracked deviation files +
# DEVIATIONS.md (the development observer path) on top of that base.  A clean-tree
# check would be wrong here — instead we verify the diff vs the fixed upstream
# base b5026c60 matches the expected deviation fileset, and that the base is an
# ancestor of HEAD (so the branch descends from the recorded upstream pin, not
# some unrelated history).  Diffing vs the fixed base (not HEAD^) correctly
# handles a branch with any number of deviation commits.  Submodules have a .git
# *file* (gitdir pointer), not a .git directory, so use `git rev-parse`.
if ! actual_commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)"; then
  echo "Source dir $source_dir is not a git checkout." >&2
  exit 1
fi
if [[ "$actual_commit" != "$expected_commit" ]]; then
  echo "SIG submodule is at $actual_commit, expected $expected_commit." >&2
  exit 1
fi
upstream_base="b5026c60fe56b51edd79131115b7e741449d6b2e"
if ! git -C "$source_dir" merge-base --is-ancestor "$upstream_base" HEAD 2>/dev/null; then
  echo "SIG deviation upstream base $upstream_base is NOT an ancestor of HEAD $actual_commit." >&2
  echo "(The branch must descend from the byte-identical upstream pin $upstream_base.)" >&2
  exit 1
fi
# Verify the deviation fileset: only these files may differ vs the upstream base.
# (bash-3.2 compatible — no mapfile/associative arrays, which macOS bash lacks.)
expected_dev_files="DEVIATIONS.md
v2/components/snapshot/api.zig
v2/lib/solana/cluster.zig
v2/main.zig
v2/services/shred_receiver.zig
v2/services/snapshot.zig"
actual_dev_files="$(git -C "$source_dir" diff --name-only "$upstream_base" HEAD)"
# Compare sorted unique sets via comm(1).
unexpected="$(printf '%s\n' "$actual_dev_files" | sort -u | comm -23 - <(printf '%s\n' "$expected_dev_files" | sort -u))"
missing="$(printf '%s\n' "$expected_dev_files" | sort -u | comm -23 - <(printf '%s\n' "$actual_dev_files" | sort -u))"
if [[ -n "$unexpected" ]]; then
  echo "SIG deviation fileset has unexpected files vs upstream base $upstream_base:" >&2
  printf '  %s\n' "$unexpected" >&2
  echo "Expected only:" >&2
  printf '  %s\n' "$expected_dev_files" >&2
  exit 1
fi
if [[ -n "$missing" ]]; then
  echo "SIG deviation fileset is missing expected files vs upstream base $upstream_base:" >&2
  printf '  %s\n' "$missing" >&2
  exit 1
fi
# Also refuse an uncommitted dirty tree on top of the deviation commit — the
# recorded deviation IS the commit, nothing more.
if [[ -n "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
  echo "SIG source has uncommitted tracked modifications on top of $actual_commit." >&2
  echo "(The deviation must be the commit itself; commit or stash extra changes.)" >&2
  exit 1
fi

echo "[build-sig] source OK: sig=$actual_commit (main; 4 deviations + DEVIATIONS.md; base $upstream_base byte-identical to upstream)"
echo "[build-sig] target: $zig_target  runtime: $runtime_platform  image: $image"

docker_context="${DOCKER_CONTEXT:-orbstack}"
# OrbStack's docker CLI ships a buildx plugin at
# /Applications/OrbStack.app/Contents/MacOS/xbin/docker-buildx; register it
# once via: ln -sf <that> ~/.docker/cli-plugins/docker-buildx
#
# Build model (see Dockerfile.sig header): the Dockerfile uses
# --platform=$BUILDPLATFORM for the builder stage so it runs NATIVELY on arm64
# (no Rosetta), avoiding the Zig 0.15.2 build_runner PRNG mis-emulation that
# crashes `shuffleWithIndex` deterministically under Rosetta (reproduced with
# seeds 0x6d3244c9 and 0xe098cf9d).  The runtime stage platform is $runtime_platform
# (linux/amd64 for x86_64 target, linux/arm64 for aarch64 target).  `--load`
# loads the single-platform image.  The builder is ALWAYS native arm64
# ($BUILDPLATFORM); -Dtarget cross-compiles the output to $zig_target.
build_args=(
  --context "$docker_context"
  buildx build
  --builder "$docker_context"
  --platform "$runtime_platform"
  --load
  --progress plain
  --build-arg "SIG_COMMIT=$expected_commit"
  --build-arg "SIG_TARGET=$zig_target"
  --build-arg "SIG_RUNTIME_PLATFORM=$runtime_platform"
  --file Dockerfile.sig
  --tag "$image"
  .
)
# NOTE: the Dockerfile clones the fork at SIG_COMMIT (not COPY from a build
# context), because the submodule .git is a gitdir pointer whose object
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

# Build-evidence check: run the binary with no config.  SIG has no --version
# flag; it takes a config path as argv[1].  With no args it returns a
# deterministic error (ConfigPathMissing) — proving the binary executes on
# the target architecture (the honest `built` check for SIG).
echo "[build-sig] build-evidence: running sig with no config (expect deterministic error)"
docker --context "$docker_context" run --rm --platform "$runtime_platform" --entrypoint /bin/bash "$image" -c '/opt/sig/bin/sig 2>&1; cat /opt/sig/BUILD-INFO' || true
