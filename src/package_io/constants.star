# Multi-client Solana Kurtosis package — shared constants.
#
# Mirrors the ethereum-package constants pattern: image tags, port IDs, and
# genesis defaults live in one place so per-client launchers share them.

# ── Port IDs (declared on every voting validator) ──────────────────────────
# Solana validator ports: rpc (TCP), gossip/tvu/tpu/tpu-forwards (UDP).
# We declare rpc as a Kurtosis port so ready_conditions / health checks work;
# UDP ports are documented but not declared (Kurtosis port-readiness would
# time out on UDP).
RPC_PORT_ID = "rpc"
# Agave's WebSocket (pubsub) port is ALWAYS rpc_port + 1 (there is no
# --rpc-pubsub-port flag in Agave 4.3.0); it starts automatically with
# --full-rpc-api. We declare it so the host can reach ws://<node>:8900.
RPC_PUBSUB_PORT_ID = "rpc-ws"
GOSSIP_PORT_ID = "gossip"
TVU_PORT_ID = "tvu"
TPU_PORT_ID = "tpu"
TPU_FW_PORT_ID = "tpu-forwards"

RPC_PORT_NUM = 8899
RPC_PUBSUB_PORT_NUM = 8900  # must equal RPC_PORT_NUM + 1
GOSSIP_PORT_NUM = 8001
TVU_PORT_NUM = 8002
TPU_PORT_NUM = 8003
TPU_FW_PORT_NUM = 8004

# ── Client images (all built + verified; see clients.lock.json) ──────────────
# Jito  : linux/arm64 (native source build from the pinned jito-solana submodule;
#         Jito publishes no arm64-linux release, so we build native. The amd64
#         release image aborts under OrbStack Rosetta with "missing AVX support".)
# Agave : linux/arm64 (native source build, has solana-genesis/solana-keygen).
# SIG   : linux/arm64 (native; deviated fork with the development-observer path
#         + the shred-stream tool → v0.2.0-arm64-functional).
JITO_IMAGE = "solana-diff/jito-solana:4.3.0-jito-amd64"
AGAVE_IMAGE = "solana-diff/agave-validator:4.3.0-amd64"
SIG_IMAGE = "solana-diff/sig:v0.2.0-amd64"
FIREDANCER_IMAGE = "solana-diff/firedancer:full-58b02033"

# The genesis-generator image must have solana-genesis + solana-keygen +
# solana-validator (for the bank-hash probe). The Agave image has all three.
GENESIS_IMAGE = AGAVE_IMAGE

# ── Genesis defaults ───────────────────────────────────────────────────────
# Sleep-mode PoH is a local development configuration. The full Firedancer
# fork explicitly supports separate transaction hashes and timer ticks.
# SIG's existing leader-schedule parser requires 432000 slots per epoch.
CLUSTER_TYPE = "development"
HASHES_PER_TICK = "sleep"
TICKS_PER_SLOT = 64
SLOTS_PER_EPOCH = 432000

FAUCET_LAMPORTS = 500000000000000          # 500M SOL faucet
BOOTSTRAP_VALIDATOR_LAMPORTS = 500000000000  # 500 SOL
BOOTSTRAP_STAKE_LAMPORTS = 100000000000      # 100 SOL stake
FIREDANCER_STAKE_LAMPORTS = 40000000000       # 40 SOL; Jito+Agave retain >80% stake

# ── Shared data mount point ─────────────────────────────────────────────────
# The genesis artifact is mounted at /data on every client. meta.env (a
# shell-sourceable KEY=VALUE file written by the genesis generator) carries
# GENESIS_HASH, SHRED_VERSION, and all pubkey material. The slot-0 BANK_HASH
# is NOT in meta.env — it is captured by a separate privileged probe service
# (bank_hash_probe.star) and interpolated into the validators' cmd as a
# literal, passed via --expected-bank-hash alongside --wait-for-supermajority 0.
GENESIS_DATA_MOUNTPOINT = "/data"

# ── Honest roles ───────────────────────────────────────────────────────────
# SIG v2 is a NON-VOTING OBSERVER (no vote/stake accounts — structurally
# impossible). The 20-slot goal is met by the two VOTING validators
# (Jito bootstrap + Agave joiner). SIG is deployed as an observer only.
ROLE_VOTING_BOOTSTRAP = "voting-bootstrap"
ROLE_VOTING_JOINER = "voting-joiner"
ROLE_SIG_OBSERVER = "sig-observer"

# Tooling service, not a validator or additional client.
VERIFIER_IMAGE = "solana-diff/network-verifier:agave-4.3.0-amd64-v1"
