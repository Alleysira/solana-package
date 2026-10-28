# Solana four-client Kurtosis network

This package launches three real voting validators (Jito-Solana, Agave and
independent full Firedancer) plus one SIG v2 non-voting observer on Linux x86_64.
It uses sleep-mode PoH, 64 ticks per slot and 100/100/40 SOL of genesis stake.
Exact source pins and capability limits are in [clients.lock.json](clients.lock.json).

Two automatic clean 600-second acceptance runs passed; see [MULTICLIENT.md](MULTICLIENT.md)
and timestamped evidence for results. The original single-test-validator README
is preserved in [README-LEGACY.md](README-LEGACY.md); its schema is historical.

## Run on the Linux server

From this directory, with the five default images already built:

    ./run-four-client.sh --fresh --observation-seconds 600

The launcher archives evidence from an existing enclave before replacing only
that enclave. It prepares Firedancer socket-buffer sysctls, runs Kurtosis with
privileged services, exports evidence on success or failure, and leaves the
network running. The default enclave is solana-four-client; --enclave NAME
selects another one. A fresh run generates new identities and genesis.

Host requirements: native x86_64 Linux with AVX2, Docker, Kurtosis, Python 3,
passwordless sudo, usable hugepages and io_uring. The tested host has 32 vCPUs
and 251 GiB RAM, with about 63 GiB reserved for Firedancer hugepages.
KVM is not needed for native execution. Firedancer development sandboxing is
disabled in this local configuration.

Default images:

| Role | Image |
| --- | --- |
| Jito | solana-diff/jito-solana:4.3.0-jito-amd64 |
| Agave/genesis tools | solana-diff/agave-validator:4.3.0-amd64 |
| Full Firedancer | solana-diff/firedancer:full-58b02033 |
| SIG observer | solana-diff/sig:v0.2.0-amd64 |
| Verification tooling | solana-diff/network-verifier:agave-4.3.0-amd64-v1 |

Build the new Firedancer and verifier images from this directory:

    sudo docker build -f Dockerfile.firedancer-full -t solana-diff/firedancer:full-58b02033 .
    sudo docker build -f Dockerfile.network-verifier -t solana-diff/network-verifier:agave-4.3.0-amd64-v1 .

The Firedancer build runs production PoH state-machine regressions before
exporting the runtime binary. The other images use the existing pinned build
scripts/Dockerfiles and their respective submodules.

## Acceptance and evidence

SIG starts from an exact full snapshot produced after a cross-node finalized
primer transfer. A real leader schedule and the existing bounded shred stream
are supplied without modifying SIG.

The observer verifies every 10 seconds over 600 seconds:

- Three exact vote identities are current, staked, and advancing votes/roots.
- Shared genesis and shred version, four peers, live SIG telemetry and process.
- Finalized slots advance on all three voting clients.
- Exact transfer signatures finalize on both Jito and Agave with correct effects.
- At least one test transfer executes in a Firedancer-led finalized block.
- At least three Firedancer leader blocks have matching hashes/parents on peers.
- All three clients observe matching recipient balances after rooting transfers.

Evidence under evidence/fourclient-UTC/ includes summary.json in verification/,
raw RPC samples, transfer signatures, public configs, compressed logs, actual
binary versions, source commits, image IDs and host details. Private keypairs
are excluded. Failure returns a nonzero launcher status and preserves evidence.

SIG is joined-only: it does not vote, continuously replay the network, or
execute transactions through an SVM at the pinned implementation. Its fixed
snapshot+96 acceptance window and one-shot shred feed are retained. Jito and
Agave share substantial code; their agreement is not an independent majority
oracle. This deployment is not itself a differential-testing campaign.

Inspect the current enclave and RPC mappings:

    sudo kurtosis enclave inspect solana-four-client

Remove only this enclave when finished:

    sudo kurtosis enclave rm -f solana-four-client
