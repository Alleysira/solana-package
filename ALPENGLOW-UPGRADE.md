# Alpenglow testnet upgrade — 2026-10-29

Goal: move all clients to current releases, run the local network with Alpenglow
enabled, and re-run the differential campaign.

## Client versions

| Client | Before | After | Notes |
|---|---|---|---|
| Agave | 4.3.0 `825efd18` | **4.4.0** `9ef63128` | latest stable release |
| Jito | 4.3.0-jito `07270be4` | **4.4.0-jito** `9a975684` | latest stable release |
| Firedancer | fork `58b0203` (0.1.1) | **v26.10.5** `6286f99e` | upstream release tag |
| SIG | v2 `0c1e96c1` | **not deployed** | see below |

### Why SIG is not in this network

SIG v2 implements **only Tower BFT**: `v1/src/consensus/` contains
`replay_tower.zig`, `tower.zig`, `fork_choice.zig` and vote tracking, with no
`votor` module and no BLS key handling anywhere in the tree.

An Alpenglow cluster reaches consensus through votor + BLS certificates, so a
Tower-only node cannot follow it. Launching SIG anyway would produce an
observer that silently falls behind, which is worse than not launching it.
The Kurtosis package now skips SIG automatically when `genesis.alpenglow` is
true.

If SIG gains Alpenglow support later, remove the `with_sig` guard in
`src/participant_network.star` and the two `topology.sig != None` checks in
`src/verification/slot_verifier.star`.

## How Alpenglow is enabled

Alpenglow is decided **at genesis**, not by a validator flag. Verified by
reading the sources:

- `agave-validator` does not read `--alpenglow` at all — the only readers are
  `solana-genesis` (`genesis/src/main.rs:818`) and `solana-test-validator`.
- `solana-genesis --alpenglow` calls `activate_all_features_alpenglow`, which
  activates the `alpenglow` feature and `configure_alpenglow_at_genesis`.
- `configure_alpenglow_at_genesis` sets `poh_config.hashes_per_tick = None`
  (low-power PoH) and inserts the genesis certificate account.
- Firedancer reads the setting from `[consensus] alpenglow` in its TOML
  (`topology.c:287` → `config->firedancer.consensus.alpenglow`), which swaps
  `repair`→`rotor`, `poh`→`motor`, and adds `votor`.

### BLS keys interoperate

Firedancer derives its BLS voting key from the identity key
(`src/disco/keyguard/fd_sign_tile.c:100`):

```c
static char const derive_msg[] = "bls-key-derive-alpenglow";
```

Agave uses `BLSKeypair::derive_from_signer(identity, BLS_KEYPAIR_DERIVE_SEED)`
with `BLS_KEYPAIR_DERIVE_SEED = b"alpenglow"`
(`votor-messages/src/consensus_message.rs:22`). The `solana-bls-signatures`
crate concatenates `b"bls-key-derive-"` with that seed, producing
`"bls-key-derive-alpenglow"` — **byte-identical to Firedancer's constant**.
The two clients derive the same BLS key from the same identity, so they can
validate each other's votes.

`--hashes-per-tick sleep` (already the package default) sets
`hashes_per_tick = None`, matching what Alpenglow requires, so there is no
conflict between the two settings.

## Changes made

### Submodules

Checked out the target commits in `agave/`, `jito-solana/`, `firedancer/`.
`sig/` left at its previous pin, unused.

`jito-solana/jito-protos/bam-protos` was restored to the commit recorded by
the `v4.4.0-jito` tag (`642c49ae`); the build script rejects a build whose
tracked tree differs from the pin.

### `solana-package/`

| File | Change |
|---|---|
| `Dockerfile.agave-validator` | commit, Cargo.lock sha256, Rust 1.98.1, cache ids, labels |
| `Dockerfile.jito-source` | same for Jito |
| `Dockerfile.firedancer-full` | build from `firedancer-io/firedancer` at v26.10.5; dropped the fork-only `test_poh_full` target |
| `Dockerfile.network-verifier` | base image 4.3.0 → 4.4.0 |
| `build-agave-validator.sh`, `build-jito-source.sh` | expected commit, `--platform linux/amd64` |
| `src/package_io/constants.star` | image tags |
| `src/package_io/input_parser.star` | new `genesis.alpenglow` knob (default false) |
| `src/genesis/genesis_launcher.star` | passes `--alpenglow` to `solana-genesis` when enabled |
| `src/firedancer/firedancer_launcher.star` | `[consensus] alpenglow = ${ALPENGLOW}` |
| `src/participant_network.star` | passes the flag to Firedancer; skips SIG when enabled |
| `src/verification/slot_verifier.star` | SIG checks conditional on `topology.sig != None` |
| `verification/verify_network.py` | tolerates a missing `sig-observer` service |
| `alpenglow-params.yaml` | `genesis: { alpenglow: true }` |

The flag defaults to **false**, so the previous four-client Tower network can
still be launched unchanged.

## Building

```bash
cd solana-package
sudo env AGAVE_VALIDATOR_IMAGE=solana-diff/agave-validator:4.4.0-amd64 \
  BUILD_JOBS=16 BUILD_DISK_FLOOR_GIB=10 ./build-agave-validator.sh
sudo env JITO_IMAGE=solana-diff/jito-solana:4.4.0-jito-amd64 \
  BUILD_JOBS=8 BUILD_DISK_FLOOR_GIB=10 ./build-jito-source.sh
sudo docker build -f Dockerfile.firedancer-full \
  -t solana-diff/firedancer:full-6286f99e .
sudo docker build -f Dockerfile.network-verifier \
  -t solana-diff/network-verifier:agave-4.4.0-amd64-v1 .
```

## Running

```bash
sudo ./prepare-fd-host.sh
sudo kurtosis run --privileged --enclave solana-alpenglow . \
  --args-file alpenglow-params.yaml
```

Expected: three voting validators (Jito + Agave + Firedancer), no SIG, all on
an Alpenglow genesis.

## Verification

```bash
# Alpenglow feature must be active in the genesis
curl -s http://<jito>:8899 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getVersion"}'

# All three must share a genesis and advance slots
curl -s http://<node>:8899 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"finalized"}]}'
```

Acceptance is the same as before minus the SIG checks: three non-delinquent
voting validators, advancing finalized slots, and a cross-node transfer.