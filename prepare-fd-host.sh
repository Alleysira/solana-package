#!/usr/bin/env bash
# Firedancer's network socket buffers are host sysctls; Docker's privileged
# container cannot write these procfs entries on this host.
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (for example, sudo $0)." >&2
  exit 1
fi
for key in net.core.rmem_max net.core.wmem_max; do
  current=$(sysctl -n "$key")
  if (( current < 134217728 )); then
    sysctl -w "$key=134217728"
  fi
done
