#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 build|run [firedancer-source-directory]" >&2
  exit 64
}

mode="${1:-}"
source_dir="${2:-../firedancer}"
case "$mode" in
  build|run) ;;
  *) usage ;;
esac

expected_commit="d70ace98ec2ddf407bfc816cc4f327ddcf6897bb"
# The release reports an approximately 109 GiB testnet footprint. Require
# 128 GiB physical RAM by default so the kernel and adjacent services retain
# headroom. This remains overrideable for a measured, dedicated environment.
minimum_ram_gib="${FIREDANCER_MIN_RAM_GIB:-$([[ "$mode" == build ]] && echo 32 || echo 128)}"
minimum_disk_gib="${FIREDANCER_MIN_DISK_GIB:-$([[ "$mode" == build ]] && echo 64 || echo 100)}"
minimum_cpus="${FIREDANCER_MIN_CPUS:-$([[ "$mode" == build ]] && echo 8 || echo 24)}"

for value in "$minimum_ram_gib" "$minimum_disk_gib" "$minimum_cpus"; do
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Resource thresholds must be positive integers." >&2
    exit 64
  fi
done

failures=0
warnings=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

host_os="$(uname -s)"
if [[ "$host_os" == Linux ]]; then
  pass "Linux host"
else
  fail "Firedancer requires Linux; found $host_os"
  printf 'SUMMARY failures=%d warnings=%d\n' "$failures" "$warnings"
  exit 1
fi

if [[ "$(uname -m)" == x86_64 ]]; then
  pass "x86_64 architecture"
else
  fail "This deployment profile is pinned to x86_64; found $(uname -m)"
fi

kernel="$(uname -r | sed 's/[^0-9.].*$//')"
if [[ "$(printf '%s\n%s\n' 4.18 "$kernel" | sort -V | head -n 1)" == 4.18 ]]; then
  pass "kernel $kernel is at least 4.18"
else
  fail "kernel $kernel is older than 4.18"
fi

ram_gib=$(( $(awk '/MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0) / 1024 / 1024 ))
if (( ram_gib >= minimum_ram_gib )); then
  pass "RAM ${ram_gib} GiB >= ${minimum_ram_gib} GiB"
else
  fail "RAM ${ram_gib} GiB < ${minimum_ram_gib} GiB"
fi

disk_probe="$source_dir"
if [[ ! -e "$disk_probe" ]]; then
  disk_probe="."
fi
disk_gib=$(( $(df -Pk "$disk_probe" | awk 'NR==2 { print $4 }') / 1024 / 1024 ))
if (( disk_gib >= minimum_disk_gib )); then
  pass "free disk ${disk_gib} GiB >= ${minimum_disk_gib} GiB"
else
  fail "free disk ${disk_gib} GiB < ${minimum_disk_gib} GiB"
fi

cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
if (( cpus >= minimum_cpus )); then
  pass "online CPUs $cpus >= $minimum_cpus"
else
  fail "online CPUs $cpus < $minimum_cpus"
fi

if grep -qw avx512f /proc/cpuinfo 2>/dev/null; then
  pass "AVX-512 is available (recommended)"
else
  warn "AVX-512 is unavailable; it is recommended but not required"
fi

if [[ "$mode" == build ]]; then
  for command in git make gcc g++ curl cmake clang protoc pkg-config; do
    if command -v "$command" >/dev/null 2>&1; then
      pass "found $command"
    else
      fail "missing build command: $command"
    fi
  done

  if [[ -d "$source_dir/.git" || -f "$source_dir/.git" ]]; then
    actual_commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$actual_commit" == "$expected_commit" ]]; then
      pass "source is pinned to $expected_commit"
    else
      fail "source commit is ${actual_commit:-unknown}; expected $expected_commit"
    fi

    if [[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
      pass "source has no tracked modifications"
    else
      fail "source has tracked modifications"
    fi

    submodule_state="$(git -C "$source_dir" submodule status agave 2>/dev/null || true)"
    case "$submodule_state" in
      -*) fail "Agave submodule is not initialized; run: git -C '$source_dir' submodule update --init --recursive" ;;
      +*) fail "Agave submodule is checked out at the wrong commit" ;;
      \ *) pass "Agave submodule is initialized at the pinned commit" ;;
      *) fail "could not determine Agave submodule state" ;;
    esac
  else
    fail "not a Firedancer Git checkout: $source_dir"
  fi
else
  if (( EUID == 0 )); then
    pass "startup user is root; Firedancer will drop to its configured user"
  else
    fail "run preflight and Firedancer startup as root (or perform the advanced capability setup documented upstream)"
  fi

  if [[ -n "${FIREDANCER_INTERFACE:-}" && -d "/sys/class/net/$FIREDANCER_INTERFACE" ]]; then
    pass "network interface $FIREDANCER_INTERFACE exists"
  else
    fail "set FIREDANCER_INTERFACE to an existing non-loopback interface"
  fi

  if mount | grep -q 'type hugetlbfs'; then
    pass "hugetlbfs is mounted"
  else
    warn "hugetlbfs is not mounted yet; `firedancer configure init all` must configure it before run"
  fi
fi

printf 'SUMMARY failures=%d warnings=%d\n' "$failures" "$warnings"
(( failures == 0 ))
