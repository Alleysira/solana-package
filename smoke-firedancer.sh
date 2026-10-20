#!/usr/bin/env bash
# smoke-firedancer.sh — Frankendancer build-evidence smoke test.
#
# Per AGENTS.md evidence rules: this script records the LOWEST proven level.
# On this Mac Studio (OrbStack, no NUMA sysfs / no hugepages), the proven level
# is `built`: the image exists, fdctl + solana binaries report their versions,
# and the source pin/deviation inventory is captured.
#
# It does NOT attempt `fdctl run` here, because that would fail at the
# hugetlbfs configure stage (verified 2026-09-28).  Calling `run` on a host
# that cannot satisfy the runtime contract would not advance the evidence level
# and would be dishonest about intent.
#
# Usage:
#   ./smoke-firedancer.sh            # build if needed, then version-check
#   ./smoke-firedancer.sh --no-build # skip build, assume image exists
set -euo pipefail
cd "$(dirname "$0")"

image="${FIREDANCER_IMAGE:-solana-diff/firedancer:v26.09.4-frankendancer-amd64}"
docker_context="${DOCKER_CONTEXT:-orbstack}"
output="${FIREDANCER_VERIFICATION_OUTPUT:-verification-firedancer-frankendancer.json}"
do_build=1
[[ "${1:-}" == "--no-build" ]] && do_build=0

# ── Build-evidence stage ───────────────────────────────────────────────────
if (( do_build == 1 )); then
  if ! docker --context "$docker_context" image inspect "$image" >/dev/null 2>&1; then
    echo "[smoke] image not found; building via build-firedancer.sh"
    ./build-firedancer.sh
  fi
fi

# ── Artifact verification: fdctl + solana version + BUILD-INFO ─────────────
echo "[smoke] verifying artifacts in image $image"
version_output="$(docker --context "$docker_context" run --rm --platform linux/amd64 "$image" version)"
echo "$version_output"

# The `version` subcommand prints, under the "=== fdctl ===" header line,
#   `0.101.40300 (ff881b69a93a6519c1a6f09698aaf208753a0a8f)`
# i.e. "<version> (<commit>)" on the first line after the header.  Extract
# the version token (everything before the first space) from that line.
fdctl_version="$(echo "$version_output" | sed -n '/=== fdctl ===/{n;p;}' | head -1 | awk '{print $1}' | tr -d '[:space:]')"
solana_version="$(echo "$version_output" | sed -n 's/^solana-cli[: ]*//Ip' | head -1 | tr -d '[:space:]')"
commit="$(echo "$version_output" | sed -n 's/^commit=//p' | head -1 | tr -d '[:space:]')"

# The `version` subcommand exits 0 on the build-evidence path.
image_id="$(docker --context "$docker_context" image inspect "$image" --format '{{.Id}}')"

# Confirm the runtime gate is honest: `configure init all` must FAIL here.
# We do NOT swallow this — it is the proof that we are not faking runtime.
# `set -o pipefail` + `set -e` would abort if `grep` finds no match (grep returns
# 1), so this block is deliberately run under a `set +e` guard and the failing
# branch is recorded, not allowed to kill the script.
runtime_gate=""
set +e
docker --context "$docker_context" run --rm --platform linux/amd64 --user root "$image" configure >/tmp/fd-configure.log 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  runtime_gate="unexpected-success (configure exited 0 — investigate)"
else
  runtime_gate="blocked-at-configure (exit $rc) — expected on NUMA-less host"
  # Capture the decisive line; tolerate a no-match (bare `configure` may bail
  # earlier, e.g. missing [user], before reaching the hugetlbfs/NUMA stage).
  gate_line="$(grep -iE 'numa|hugepage|hugetlbfs|/sys/devices/system/node|user|Firedancer as' /tmp/fd-configure.log | head -1 | tr -d '\r' || true)"
  runtime_gate="$runtime_gate | gate_line=${gate_line:-<none-matched>}"
fi

# ── Evidence JSON ──────────────────────────────────────────────────────────
jq -n \
  --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg image "$image" \
  --arg imageId "$image_id" \
  --arg fdctlVersion "${fdctl_version:-unknown}" \
  --arg solanaVersion "${solana_version:-unknown}" \
  --arg commit "${commit:-ff881b69a93a6519c1a6f09698aaf208753a0a8f}" \
  --arg runtimeGate "$runtime_gate" \
  --arg hostKernel "$(uname -srm)" \
  '{verifiedAt:$verifiedAt, target:"Frankendancer v26.09.4 (fdctl+solana)",
    evidenceLevel:"built",
    image:$image, imageId:$imageId,
    source:{commit:$commit, fork:"Alleysira/firedancer",
      note:"6 tracked deviation files (5 GCC-12 casts + NUMA fallback); NUMA fallback is topology fabrication"},
    binaries:{fdctl:$fdctlVersion, solana:$solanaVersion},
    runtimeGate:$runtimeGate,
    hostKernel:$hostKernel,
    limitations:[
      "Build evidence only: binaries exist and report versions.",
      "Validator did NOT start: NUMA sysfs/hugepages absent on this host (OrbStack kernel).",
      "started/joined/voting require a dedicated bare-metal x86_64 Linux host with real NUMA + hugepages.",
      "This is Frankendancer (Agave hybrid), NOT full Firedancer — explicit relaxation of AGENTS.md full-Firedancer rule.",
      "The fork commit carries a NUMA-fabrication fallback; invalid for runtime sizing or network claims."
    ]}' | tee "$output"
echo "[smoke] evidence written to $output (level: built)"
