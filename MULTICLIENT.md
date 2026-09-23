# Multi-client testnet status

The exact acceptance target—five voting validators, one from every client in
the Solana documentation, while using every project's latest stable release—is
not currently satisfiable upstream.

`clients.lock.json` is the machine-readable source of truth for versions,
commits, capability, and evidence. It intentionally separates a project's name
from what the pinned release can actually run.

| Client | Pinned stable release | Voting validator | Same 4.3 genesis | Local evidence |
| --- | --- | ---: | ---: | --- |
| Agave | `v4.3.0` | yes | expected | test-validator verified; full validator build pending |
| Jito-Solana | `v4.3.0-jito` | yes | verified | real validator and two-node shared-genesis topology verified |
| Firedancer | `v26.09.4` | yes | candidate | upstream says 4.3 support; capable host required |
| Solana Labs | `v1.18.26` | yes | no | both genesis directions rejected in local probes |
| Sig | `v0.1.0` | no | n/a | stable release is an RPC static library |

## What is verified

Jito-Solana ran as a real voting validator, advanced slots, and finalized a
1 SOL transfer. The container ran without privilege, Linux capabilities, or
`no-new-privileges`/seccomp exceptions. See `verification-jito430.json`.

The shared-genesis harness also cold-started two independent Jito validators
with distinct identity, vote, stake, and BLS keys. Both nodes reported the same
genesis hash, appeared in the gossip table, became non-delinquent voting
validators, advanced slots, and observed a 1 SOL transfer at finalized
commitment through different RPC nodes. See `verification-shared-genesis.json`.
This validates the multi-node orchestration, not client diversity: both
binaries identify themselves as `JitoLabs` and use the same immutable image.

Agave `solana-test-validator` 4.3.0 passed RPC, WebSocket, finalized transfer,
and program execution checks. This proves the toolchain image but is not a
substitute for the pending full `agave-validator` build.

## Why five latest-stable validators cannot be claimed

Solana Labs 1.18 and the current 4.3 family disagree about the genesis/vote
account representation. Disabling features did not resolve this: each genesis
direction failed before normal voting could begin.

Sig's stable tag contains an RPC library, not a validator executable. Current
Sig `main` is much further along, but upstream still calls it incomplete and
documents external Agave leader-schedule and shred-stream requirements.

## Executable next milestone

1. Rebuild full Agave and Jito on a machine with sufficient disk, using their
   already-separated BuildKit caches.
2. Re-run the verified shared-genesis harness with the full Agave image as
   `JOINER_IMAGE`; the current evidence uses two Jito nodes and therefore does
   not yet prove Agave/Jito client diversity.
3. Build and add Firedancer 26.09.4 on a dedicated Linux x86_64 host with at
   least 128 GiB physical RAM (the release reports a ~109 GiB testnet
   footprint). Use `deploy/firedancer/` for the preflight
   and host deployment boundary.
4. Choose one relaxation for each upstream conflict: use a protocol-compatible
   Solana Labs revision instead of latest stable, and use Sig `main` as a
   non-voting observer—or wait for an upstream complete stable Sig validator.

The package must not label an observer, RPC library, or aliased Agave process
as a distinct voting client merely to reach a count of five.
