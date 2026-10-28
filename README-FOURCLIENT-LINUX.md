# Four-client Linux experiment

Target: Jito-Solana and Agave voting validators, independent full Firedancer
voting validator, and SIG v2 non-voting observer. This is an experimental
extension of the previously verified three-client package. Only evidence in
`evidence/fourclient-20261028/` establishes its achieved level.

On the pinned x86_64 checkout, build the images with Docker Buildx:

```bash
docker buildx build --build-context agave_source=../agave -f Dockerfile.agave-validator -t solana-diff/agave-validator:4.3.0-amd64 --load .
docker buildx build --build-context jito_source=../jito-solana -f Dockerfile.jito-source -t solana-diff/jito-solana:4.3.0-jito-amd64 --load .
docker buildx build -f Dockerfile.sig -t solana-diff/sig:v0.2.0-amd64 --load .
docker build -f Dockerfile.firedancer-full -t solana-diff/firedancer:full-ff881b69 .
```

The host must expose NUMA and hugepage sysfs. Full Firedancer's reduced testnet
configuration requests about 55 GiB of two-megabyte hugepages. This GCP guest
has no `/dev/kvm`; KVM was not required for the native x86_64 containers.
Run `sudo ./prepare-fd-host.sh` before starting Kurtosis. It raises the host
socket receive/send maxima to 128 MiB; this host does not permit the privileged
container to change those sysctls itself.
Run the package from a clean enclave:

```bash
kurtosis run --privileged --enclave solana-four-client .
```

The genesis generator gives Jito and Agave 100 SOL of stake each and Firedancer
40 SOL through Agave's `--validator-accounts-file`. This lets the first two
validators finalize and produce a snapshot while Firedancer loads it. The
genesis uses a numeric PoH hash count (62,500 hashes per tick, 128 ticks per
slot): this pinned full Firedancer crashes with `hashes_per_tick=sleep` and
rejects blocks above 62,500 hashes per tick. Firedancer fetches full snapshots
from the Jito RPC explicitly because its snapshot selector discards private
RPC addresses learned only through gossip. Incremental snapshots are disabled
on both ends. The local GUI database is disabled, and the account and shred
store sizes are reduced for the 96 GiB host root volume.
The package waits for all three voting validators to be non-delinquent. A
successful run must also show four peers in the bootstrap
gossip view, finalized slot advancement, and a cross-node finalized transfer.
Capture the Kurtosis run log, each service log, `validators.txt`, `gossip.txt`,
the generated evidence JSON, image IDs, and host details before cleaning up.
Do not treat a build or live process as a joined or voting full validator.

The latest strict run (2026-10-28, attempt 16) failed at the final Firedancer
delinquency check. All four nodes appeared in gossip and Firedancer voted
briefly, but it fell behind Jito and Agave. See
`evidence/fourclient-20261028/summary.json` and the root
`HANDOFF-FIREDANCER-2026-10-28-2.md`. No passing four-client end-to-end run
has been recorded.
