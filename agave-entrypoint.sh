#!/usr/bin/env bash
set -euo pipefail

node /app/dist/index.js &
api_pid=$!
"$@" &
validator_pid=$!

cleanup() {
  kill -TERM "$api_pid" "$validator_pid" 2>/dev/null || true
  wait "$api_pid" "$validator_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Fail the container if either required service exits.
set +e
wait -n -p finished_pid "$api_pid" "$validator_pid"
status=$?
set -e
if [[ "$status" -eq 0 && "$finished_pid" -eq "$api_pid" ]]; then status=1; fi
exit "$status"
