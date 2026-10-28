#!/usr/bin/env bash
# Run from the Linux host; preserve evidence even when Kurtosis rejects the run.
set -euo pipefail
cd "$(dirname "$0")"
enclave=solana-four-client
seconds=600
fresh=false
while (($#)); do
  case "$1" in
    --enclave) enclave=$2; shift 2 ;;
    --observation-seconds) seconds=$2; shift 2 ;;
    --fresh) fresh=true; shift ;;
    *) echo "Usage: $0 [--enclave NAME] [--observation-seconds N] [--fresh]" >&2; exit 2 ;;
  esac
done
[[ $enclave =~ ^[a-zA-Z0-9_-]+$ && $seconds =~ ^[0-9]+$ && $seconds -ge 60 ]] || exit 2
run_id=$(date -u +%Y%m%dT%H%M%SZ)
evidence="evidence/fourclient-$run_id"
mkdir -p "$evidence"
if $fresh; then
  if sudo -n docker network inspect "kt-$enclave" >/dev/null 2>&1; then
    python3 verification/export_evidence.py --enclave "$enclave" --out "$evidence/previous"
    sudo -n kurtosis enclave rm -f "$enclave"
  fi
elif sudo -n docker network inspect "kt-$enclave" >/dev/null 2>&1; then
  echo "Enclave already exists. Use --fresh to archive its evidence and recreate it." >&2
  exit 2
fi
python3 - "$evidence" <<'PY_SOURCES'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path.cwd().parent
sources = {}
for name in [".", "firedancer", "agave", "jito-solana", "sig", "solana-package"]:
    repo = root / name
    sources[name] = {
        "commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
        "trackedChanges": subprocess.check_output(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=no"], text=True),
    }
sources["verificationScriptSha256"] = hashlib.sha256(pathlib.Path("verification/verify_network.py").read_bytes()).hexdigest()
pathlib.Path(sys.argv[1], "deployed-sources.json").write_text(json.dumps(sources, indent=2) + "\n")
PY_SOURCES
sudo -n ./prepare-fd-host.sh
config=$(python3 -c 'import json,sys; print(json.dumps({"verification":{"observation_seconds":int(sys.argv[1])}}))' "$seconds")
printf '%s\n' "$config" > "$evidence/args.json"
set +e
sudo -n kurtosis run --privileged --enclave "$enclave" . "$config" 2>&1 | tee "$evidence/run.log"
result=${PIPESTATUS[0]}
set -e
python3 verification/export_evidence.py --enclave "$enclave" --out "$evidence"
printf '%s\n' "$result" > "$evidence/kurtosis-exit-code.txt"
printf 'Evidence: %s\n' "$evidence"
exit "$result"
