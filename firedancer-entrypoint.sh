#!/usr/bin/env bash
# firedancer-entrypoint.sh — container entrypoint for Frankendancer (fdctl).
#
# Honesty contract (see Dockerfile.firedancer header + README):
#   - This entrypoint supports BOTH a build-evidence invocation (default on
#     hosts without NUMA/hugepages) and a real run invocation (on a dedicated
#     x86_64 Linux host with NUMA sysfs + hugepages + root).
#   - It NEVER fakes NUMA or hugepages.  If `configure init` cannot satisfy the
#     hugetlbfs stage, it exits non-zero with the real error, rather than
#     silently skipping the gate.
#
# Subcommands:
#   run        (default) configure init all, then fdctl run
#   configure  configure init all only (no run)
#   version    print fdctl + solana versions and exit (build-evidence default)
#   <other>    pass through to fdctl verbatim (e.g. keys, monitor, solana)
set -euo pipefail

BIN=/opt/firedancer/bin
CMD="${1:-run}"
case "$CMD" in
  run)
    # Real validator start.  Requires root + NUMA + hugepages.
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "fdctl run requires root for configure init all (hugepages/sysctls)." >&2
      exit 1
    fi
    echo "[entrypoint] fdctl configure init all"
    "$BIN/fdctl" configure init all
    echo "[entrypoint] fdctl run"
    exec "$BIN/fdctl" run
    ;;
  configure)
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "fdctl configure requires root for init all." >&2
      exit 1
    fi
    exec "$BIN/fdctl" configure init all
    ;;
  version)
    # Build-evidence invocation.  Prints versions and exits 0.  Use this on
    # hosts where the validator cannot start (e.g. this Mac Studio).
    echo "=== fdctl ==="
    "$BIN/fdctl" version
    echo "=== solana ==="
    "$BIN/solana" --version
    echo "=== BUILD-INFO ==="
    cat /opt/firedancer/BUILD-INFO
    echo "=== SUBMODULE-STATUS ==="
    cat /opt/firedancer/SUBMODULE-STATUS
    ;;
  solana)
    shift
    exec "$BIN/solana" "$@"
    ;;
  *)
    # Pass through to fdctl for any other subcommand (keys, monitor, etc.).
    exec "$BIN/fdctl" "$@"
    ;;
esac
