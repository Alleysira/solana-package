#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

image="${JITO_IMAGE:-solana-diff/jito-solana:4.3.0-jito-arm64}"
platform="${JITO_PLATFORM:-linux/arm64}"
output="${JITO_VERIFICATION_OUTPUT:-verification-jito430.json}"
work_dir=$(mktemp -d /tmp/solana-jito-native-smoke.XXXXXX)
container="solana-jito-native-smoke-$RANDOM"

cleanup() {
  docker stop --time 10 "$container" >/dev/null 2>&1 || true
  docker rm "$container" >/dev/null 2>&1 || true
  case "$work_dir" in
    /tmp/solana-jito-native-smoke.*) rm -rf -- "$work_dir" ;;
  esac
}
trap cleanup EXIT

run_tool() {
  docker run --rm --platform "$platform" -v "$work_dir:/data" "$image" "$@"
}

for key in identity vote stake faucet tip-payment tip-distribution merkle-authority recipient; do
  run_tool solana-keygen new --no-bip39-passphrase --silent --force \
    --outfile "/data/$key.json" >/dev/null
done

identity=$(run_tool solana-keygen pubkey /data/identity.json)
vote=$(run_tool solana-keygen pubkey /data/vote.json)
stake=$(run_tool solana-keygen pubkey /data/stake.json)
recipient=$(run_tool solana-keygen pubkey /data/recipient.json)
tip_payment=$(run_tool solana-keygen pubkey /data/tip-payment.json)
tip_distribution=$(run_tool solana-keygen pubkey /data/tip-distribution.json)
merkle_authority=$(run_tool solana-keygen pubkey /data/merkle-authority.json)
bls=$(run_tool solana-keygen bls_pubkey /data/identity.json)

run_tool solana-genesis \
  --ledger /data/ledger \
  --bootstrap-validator "$identity" "$vote" "$stake" \
  --bootstrap-validator-bls-pubkey "$bls" \
  --faucet-pubkey /data/faucet.json \
  --faucet-lamports 500000000000000 \
  --bootstrap-validator-lamports 500000000000 \
  --bootstrap-validator-stake-lamports 100000000000 \
  --cluster-type development \
  --hashes-per-tick sleep \
  --ticks-per-slot 8 \
  --slots-per-epoch 128 >/dev/null

docker run -d --name "$container" --platform "$platform" \
  --security-opt seccomp=./seccomp/agave.json \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$work_dir:/data" \
  "$image" \
  agave-validator \
  --ledger /data/ledger \
  --identity /data/identity.json \
  --vote-account "$vote" \
  --rpc-bind-address 0.0.0.0 \
  --rpc-port 8899 \
  --gossip-port 8001 \
  --dynamic-port-range 8002-8035 \
  --full-rpc-api \
  --no-snapshots \
  --no-xdp \
  --no-os-network-limits-test \
  --no-poh-speed-test \
  --no-port-check \
  --no-wait-for-vote-to-start-leader \
  --limit-blockstore-size 100000000 \
  --block-engine-url '' \
  --relayer-url '' \
  --tip-payment-program-pubkey "$tip_payment" \
  --tip-distribution-program-pubkey "$tip_distribution" \
  --merkle-root-upload-authority "$merkle_authority" \
  --commission-bps 0 \
  --log - >/dev/null

ready=0
for _ in $(seq 1 120); do
  if docker exec "$container" solana --url http://127.0.0.1:8899 slot \
      >"$work_dir/slot" 2>/dev/null; then
    ready=1
    break
  fi
  if [[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null || true)" != true ]]; then
    break
  fi
  sleep 1
done
if (( ready == 0 )); then
  docker logs "$container" 2>&1 | tail -200 >&2
  exit 1
fi

slot_start=$(tr -d '[:space:]' <"$work_dir/slot")
sleep 3
slot_end=$(docker exec "$container" solana --url http://127.0.0.1:8899 slot | tr -d '[:space:]')
(( slot_end > slot_start ))

version=$(docker exec "$container" solana --url http://127.0.0.1:8899 cluster-version | tr -d '\r')
genesis=$(docker exec "$container" solana --url http://127.0.0.1:8899 genesis-hash | tr -d '\r')
validators=$(docker exec "$container" solana --url http://127.0.0.1:8899 validators --output json-compact | tr -d '\r')
validator_record=$(jq -cer --arg identity "$identity" \
  '.validators[] | select(.identityPubkey == $identity and .delinquent == false and .lastVote > 0)' \
  <<<"$validators")
transfer=$(docker exec "$container" solana --url http://127.0.0.1:8899 \
  --keypair /data/identity.json --commitment finalized \
  transfer "$recipient" 1 --allow-unfunded-recipient --output json-compact | tr -d '\r')
signature=$(jq -er '.signature' <<<"$transfer")
balance=$(docker exec "$container" solana --url http://127.0.0.1:8899 \
  --commitment finalized balance "$recipient" --lamports | awk '{print $1}')
[[ "$balance" == 1000000000 ]]

binary_version=$(docker exec "$container" agave-validator --version | tr -d '\r')
container_info=$(docker inspect "$container")
image_info=$(docker image inspect "$image")
image_id=$(jq -er '.[0].Image' <<<"$container_info")
architecture=$(jq -er '.[0].Architecture' <<<"$image_info")
source_commit=$(jq -er '.[0].Config.Labels["org.opencontainers.image.revision"]' <<<"$image_info")
privileged=$(jq -r '.[0].HostConfig.Privileged' <<<"$container_info")
cap_eff=$(docker exec "$container" awk '/^CapEff:/ {print $2}' /proc/1/status)
cap_bnd=$(docker exec "$container" awk '/^CapBnd:/ {print $2}' /proc/1/status)
no_new_privs=$(docker exec "$container" awk '/^NoNewPrivs:/ {print $2}' /proc/1/status)
seccomp=$(docker exec "$container" awk '/^Seccomp:/ {print $2}' /proc/1/status)

jq -n \
  --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg version "$version" \
  --arg binaryVersion "$binary_version" \
  --arg imageId "$image_id" \
  --arg architecture "$architecture" \
  --arg sourceCommit "$source_commit" \
  --arg genesisHash "$genesis" \
  --arg identity "$identity" \
  --arg vote "$vote" \
  --arg bls "$bls" \
  --argjson slotStart "$slot_start" \
  --argjson slotEnd "$slot_end" \
  --argjson validator "$validator_record" \
  --arg signature "$signature" \
  --arg recipient "$recipient" \
  --argjson recipientLamports "$balance" \
  --argjson privileged "$privileged" \
  --arg capEff "$cap_eff" \
  --arg capBnd "$cap_bnd" \
  --argjson noNewPrivs "$no_new_privs" \
  --argjson seccomp "$seccomp" \
  '{verifiedAt:$verifiedAt, client:"JitoLabs", version:$version,
    binaryVersion:$binaryVersion, imageId:$imageId, architecture:$architecture,
    sourceCommit:$sourceCommit, genesisHash:$genesisHash,
    validator:{identity:$identity,vote:$vote,bls:$bls,rpcRecord:$validator},
    slots:{start:$slotStart,end:$slotEnd},
    transfer:{signature:$signature,recipient:$recipient,recipientLamports:$recipientLamports},
    isolation:{privileged:$privileged,capEff:$capEff,capBnd:$capBnd,
      noNewPrivs:$noNewPrivs,seccompMode:$seccomp}}' | tee "$output"
