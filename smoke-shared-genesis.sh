#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# This harness is intentionally client-agnostic. Today it can prove the shared
# genesis topology with two Jito images; once the Agave full-validator image is
# available, set JOINER_IMAGE to that image without changing the network logic.
bootstrap_image="${BOOTSTRAP_IMAGE:-solana-diff/jito-solana:4.3.0-jito-arm64}"
joiner_image="${JOINER_IMAGE:-solana-diff/jito-solana:4.3.0-jito-arm64}"
bootstrap_platform="${BOOTSTRAP_PLATFORM:-linux/arm64}"
joiner_platform="${JOINER_PLATFORM:-linux/arm64}"
output="${SHARED_GENESIS_VERIFICATION_OUTPUT:-verification-shared-genesis.json}"

work_dir="$(mktemp -d /tmp/solana-shared-genesis.XXXXXX)"
network="solana-shared-$RANDOM-$RANDOM"
bootstrap_container="${network}-bootstrap"
joiner_container="${network}-joiner"
probe_container="${network}-bank-hash-probe"
subnet=""

cleanup() {
  docker stop --time 10 "$joiner_container" "$bootstrap_container" "$probe_container" >/dev/null 2>&1 || true
  docker rm "$joiner_container" "$bootstrap_container" "$probe_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  case "$work_dir" in
    /tmp/solana-shared-genesis.*) rm -rf -- "$work_dir" ;;
  esac
}
trap cleanup EXIT

run_tool() {
  local image="$1"
  local platform="$2"
  shift 2
  docker run --rm --platform "$platform" -v "$work_dir:/data" "$image" "$@"
}

for third_octet in $(seq 80 99); do
  candidate="172.29.${third_octet}.0/24"
  if docker network create --subnet "$candidate" "$network" >/dev/null 2>&1; then
    subnet="$candidate"
    break
  fi
done
if [[ -z "$subnet" ]]; then
  echo "Could not allocate an isolated Docker subnet." >&2
  exit 1
fi
third_octet="${subnet#172.29.}"
third_octet="${third_octet%%.*}"
bootstrap_ip="172.29.${third_octet}.2"
joiner_ip="172.29.${third_octet}.3"

for key in bootstrap-identity bootstrap-vote bootstrap-stake \
           joiner-identity joiner-vote joiner-stake \
           faucet tip-payment tip-distribution merkle-authority recipient; do
  run_tool "$bootstrap_image" "$bootstrap_platform" solana-keygen new \
    --no-bip39-passphrase --silent --force --outfile "/data/$key.json" >/dev/null
done

pubkey() {
  run_tool "$bootstrap_image" "$bootstrap_platform" solana-keygen pubkey "/data/$1.json"
}
bootstrap_identity="$(pubkey bootstrap-identity)"
bootstrap_vote="$(pubkey bootstrap-vote)"
bootstrap_stake="$(pubkey bootstrap-stake)"
joiner_identity="$(pubkey joiner-identity)"
joiner_vote="$(pubkey joiner-vote)"
joiner_stake="$(pubkey joiner-stake)"
recipient="$(pubkey recipient)"
tip_payment="$(pubkey tip-payment)"
tip_distribution="$(pubkey tip-distribution)"
merkle_authority="$(pubkey merkle-authority)"
bootstrap_bls="$(run_tool "$bootstrap_image" "$bootstrap_platform" solana-keygen bls_pubkey /data/bootstrap-identity.json)"
joiner_bls="$(run_tool "$bootstrap_image" "$bootstrap_platform" solana-keygen bls_pubkey /data/joiner-identity.json)"

genesis_output="$(run_tool "$bootstrap_image" "$bootstrap_platform" solana-genesis \
  --ledger /data/genesis-ledger \
  --bootstrap-validator "$bootstrap_identity" "$bootstrap_vote" "$bootstrap_stake" \
  --bootstrap-validator "$joiner_identity" "$joiner_vote" "$joiner_stake" \
  --bootstrap-validator-bls-pubkey "$bootstrap_bls" \
  --bootstrap-validator-bls-pubkey "$joiner_bls" \
  --faucet-pubkey /data/faucet.json \
  --faucet-lamports 500000000000000 \
  --bootstrap-validator-lamports 500000000000 \
  --bootstrap-validator-stake-lamports 100000000000 \
  --cluster-type development \
  --hashes-per-tick sleep \
  --ticks-per-slot 8 \
  --slots-per-epoch 128)"
genesis_hash="$(awk -F': ' '/Genesis hash:/ {print $2}' <<<"$genesis_output" | tr -d '[:space:]')"
shred_version="$(awk -F': ' '/Shred version:/ {print $2}' <<<"$genesis_output" | tr -d '[:space:]')"
[[ -n "$genesis_hash" && "$shred_version" =~ ^[0-9]+$ ]]

run_tool "$bootstrap_image" "$bootstrap_platform" bash -ec '
  mkdir -p /data/probe-ledger /data/bootstrap-ledger /data/joiner-ledger
  cp -a /data/genesis-ledger/. /data/probe-ledger/
  cp -a /data/genesis-ledger/. /data/bootstrap-ledger/
  cp -a /data/genesis-ledger/. /data/joiner-ledger/
'

common_args=(
  --rpc-bind-address 0.0.0.0
  --rpc-port 8899
  --gossip-port 8001
  --dynamic-port-range 8002-8035
  --full-rpc-api
  --enable-rpc-transaction-history
  --no-snapshots
  --no-genesis-fetch
  --no-snapshot-fetch
  --no-xdp
  --no-os-network-limits-test
  --no-poh-speed-test
  --no-port-check
  --allow-private-addr
  --no-wait-for-vote-to-start-leader
  --limit-blockstore-size 100000000
  --expected-genesis-hash "$genesis_hash"
  --expected-shred-version "$shred_version"
  --block-engine-url ''
  --relayer-url ''
  --tip-payment-program-pubkey "$tip_payment"
  --tip-distribution-program-pubkey "$tip_distribution"
  --merkle-root-upload-authority "$merkle_authority"
  --commission-bps 0
  --log -
)

# Slot zero's bank hash is deterministic for a genesis ledger, but it is not
# the same value as the genesis hash. Start a short-lived single node to expose
# it over RPC, then start the real pair from untouched copies of the ledger.
docker run -d --name "$probe_container" --platform "$bootstrap_platform" \
  --network "$network" --ip "$bootstrap_ip" \
  --security-opt seccomp=./seccomp/agave.json --cap-drop ALL \
  --security-opt no-new-privileges -v "$work_dir:/data" \
  "$bootstrap_image" agave-validator \
  --ledger /data/probe-ledger \
  --identity /data/bootstrap-identity.json \
  --vote-account "$bootstrap_vote" \
  --bind-address "$bootstrap_ip" \
  --gossip-host "$bootstrap_ip" \
  --public-tpu-address "$bootstrap_ip:8003" \
  --public-tpu-forwards-address "$bootstrap_ip:8004" \
  --public-tvu-address "$bootstrap_ip:8002" \
  "${common_args[@]}" >/dev/null

bank_hash=""
for _ in $(seq 1 90); do
  bank_hash="$(docker logs "$probe_container" 2>&1 | \
    sed -n 's/.*bank frozen: 0 hash: \([^ ]*\).*/\1/p' | tail -n 1)"
  if [[ -n "$bank_hash" ]]; then
    break
  fi
  if [[ "$(docker inspect "$probe_container" --format '{{.State.Running}}' 2>/dev/null || true)" != true ]]; then
    docker logs "$probe_container" 2>&1 | tail -200 >&2
    exit 1
  fi
  sleep 1
done
if [[ -z "$bank_hash" ]]; then
  echo "Could not obtain the deterministic slot-zero bank hash." >&2
  exit 1
fi
docker stop --time 10 "$probe_container" >/dev/null
docker rm "$probe_container" >/dev/null

docker run -d --name "$bootstrap_container" --platform "$bootstrap_platform" \
  --network "$network" --ip "$bootstrap_ip" \
  --security-opt seccomp=./seccomp/agave.json --cap-drop ALL \
  --security-opt no-new-privileges -v "$work_dir:/data" \
  "$bootstrap_image" agave-validator \
  --ledger /data/bootstrap-ledger \
  --identity /data/bootstrap-identity.json \
  --vote-account "$bootstrap_vote" \
  --bind-address "$bootstrap_ip" \
  --gossip-host "$bootstrap_ip" \
  --public-tpu-address "$bootstrap_ip:8003" \
  --public-tpu-forwards-address "$bootstrap_ip:8004" \
  --public-tvu-address "$bootstrap_ip:8002" \
  --wait-for-supermajority 0 \
  --expected-bank-hash "$bank_hash" \
  "${common_args[@]}" >/dev/null

docker run -d --name "$joiner_container" --platform "$joiner_platform" \
  --network "$network" --ip "$joiner_ip" \
  --security-opt seccomp=./seccomp/agave.json --cap-drop ALL \
  --security-opt no-new-privileges -v "$work_dir:/data" \
  "$joiner_image" agave-validator \
  --ledger /data/joiner-ledger \
  --identity /data/joiner-identity.json \
  --vote-account "$joiner_vote" \
  --entrypoint "$bootstrap_ip:8001" \
  --bind-address "$joiner_ip" \
  --gossip-host "$joiner_ip" \
  --public-tpu-address "$joiner_ip:8003" \
  --public-tpu-forwards-address "$joiner_ip:8004" \
  --public-tvu-address "$joiner_ip:8002" \
  --wait-for-supermajority 0 \
  --expected-bank-hash "$bank_hash" \
  "${common_args[@]}" >/dev/null

ready=0
for _ in $(seq 1 180); do
  if validators="$(docker exec "$bootstrap_container" solana --url http://127.0.0.1:8899 validators --output json-compact 2>/dev/null)"; then
    active_count="$(jq -r --arg first "$bootstrap_identity" --arg second "$joiner_identity" \
      '[.validators[] | select((.identityPubkey == $first or .identityPubkey == $second) and .delinquent == false and .lastVote > 0)] | length' \
      <<<"$validators")"
    if [[ "$active_count" == 2 ]]; then
      ready=1
      break
    fi
  fi
  for container in "$bootstrap_container" "$joiner_container"; do
    if [[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null || true)" != true ]]; then
      echo "$container exited before the network became ready" >&2
      docker logs "$container" 2>&1 | tail -200 >&2
      exit 1
    fi
  done
  sleep 1
done
if (( ready == 0 )); then
  docker logs "$bootstrap_container" 2>&1 | tail -100 >&2
  docker logs "$joiner_container" 2>&1 | tail -100 >&2
  exit 1
fi

slot_start="$(docker exec "$bootstrap_container" solana --url http://127.0.0.1:8899 slot | tr -d '[:space:]')"
bootstrap_genesis_hash="$(docker exec "$bootstrap_container" solana --url http://127.0.0.1:8899 genesis-hash | tr -d '[:space:]')"
joiner_genesis_hash="$(docker exec "$joiner_container" solana --url http://127.0.0.1:8899 genesis-hash | tr -d '[:space:]')"
[[ -n "$bootstrap_genesis_hash" && "$bootstrap_genesis_hash" == "$joiner_genesis_hash" ]]
genesis_hash="$bootstrap_genesis_hash"
sleep 3
slot_end="$(docker exec "$bootstrap_container" solana --url http://127.0.0.1:8899 slot | tr -d '[:space:]')"
(( slot_end > slot_start ))

transfer="$(docker exec "$bootstrap_container" solana --url http://127.0.0.1:8899 \
  --keypair /data/bootstrap-identity.json --commitment finalized transfer "$recipient" 1 \
  --allow-unfunded-recipient --output json-compact)"
signature="$(jq -er '.signature' <<<"$transfer")"
recipient_lamports="$(docker exec "$joiner_container" solana --url http://127.0.0.1:8899 \
  --commitment finalized balance "$recipient" --lamports | awk '{print $1}')"
[[ "$recipient_lamports" == 1000000000 ]]

gossip_nodes="$(docker exec "$bootstrap_container" solana \
  --url http://127.0.0.1:8899 gossip --output json-compact)"
gossip_count="$(jq -r --arg first "$bootstrap_identity" --arg second "$joiner_identity" \
  '[.[] | select(.identityPubkey == $first or .identityPubkey == $second)] | length' <<<"$gossip_nodes")"
[[ "$gossip_count" == 2 ]]
bootstrap_version="$(docker exec "$bootstrap_container" agave-validator --version | tr -d '\r')"
joiner_version="$(docker exec "$joiner_container" agave-validator --version | tr -d '\r')"
bootstrap_image_id="$(docker image inspect "$bootstrap_image" --format '{{.Id}}')"
joiner_image_id="$(docker image inspect "$joiner_image" --format '{{.Id}}')"

jq -n \
  --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg genesisHash "$genesis_hash" \
  --arg bootstrapIdentity "$bootstrap_identity" \
  --arg bootstrapVote "$bootstrap_vote" \
  --arg bootstrapVersion "$bootstrap_version" \
  --arg bootstrapImage "$bootstrap_image" \
  --arg bootstrapImageId "$bootstrap_image_id" \
  --arg joinerIdentity "$joiner_identity" \
  --arg joinerVote "$joiner_vote" \
  --arg joinerVersion "$joiner_version" \
  --arg joinerImage "$joiner_image" \
  --arg joinerImageId "$joiner_image_id" \
  --argjson validators "$validators" \
  --argjson gossipNodes "$gossip_nodes" \
  --argjson slotStart "$slot_start" \
  --argjson slotEnd "$slot_end" \
  --arg signature "$signature" \
  --arg recipient "$recipient" \
  --argjson recipientLamports "$recipient_lamports" \
  '{verifiedAt:$verifiedAt, topology:"shared-genesis-two-validator",
    genesisHash:$genesisHash,
    nodes:[
      {role:"bootstrap",identity:$bootstrapIdentity,vote:$bootstrapVote,
       binaryVersion:$bootstrapVersion,image:$bootstrapImage,imageId:$bootstrapImageId},
      {role:"joiner",identity:$joinerIdentity,vote:$joinerVote,
       binaryVersion:$joinerVersion,image:$joinerImage,imageId:$joinerImageId}
    ], validators:$validators, gossipNodes:$gossipNodes,
    slots:{start:$slotStart,end:$slotEnd},
    transfer:{signature:$signature,recipient:$recipient,recipientLamports:$recipientLamports}}' | tee "$output"
