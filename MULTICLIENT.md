# Multi-client testnet status

The exact acceptance target—five voting validators, one from every client in
the Solana documentation, while using every project's latest stable release—is
not currently satisfiable upstream.

`clients.lock.json` is the machine-readable source of truth for versions,
commits, capability, and evidence. It intentionally separates a project's name
from what the pinned release can actually run.

| Client | Pinned stable release | Voting validator | Same 4.3 genesis | Local evidence |
| --- | --- | ---: | ---: | --- |
| Agave | `v4.3.0` | yes | verified | full `agave-validator` voting as joiner in the mixed-client shared-genesis run (2026-09-30); `solana-test-validator` separately verified |
| Jito-Solana | `v4.3.0-jito` | yes | verified | real validator; client-diversity-proven as bootstrap in the mixed-client shared-genesis run with an Agave joiner (2026-09-30) |
| Firedancer | `v26.09.4` | yes | candidate | Official docs (docs.firedancer.io/guide/getting-started.html, inspected 2026-09-28) label v26.09.4 as the Frankendancer (Agave hybrid) build target and state "It is not yet possible to run a full Firedancer validator." Container path targets Frankendancer (`fdctl`+`solana`) — an explicit, recorded relaxation of the full-Firedancer rule. The workspace submodule is the `Alleysira/firedancer` fork @ `ff881b69` carrying 6 tracked deviation files (5 GCC-12 casts + a NUMA-fabrication fallback). **Image built**: `solana-diff/firedancer:v26.09.4-frankendancer-amd64` (11.9 GiB); `fdctl`/`solana` = `0.101.40300 (client:Frankendancer)`; agave submodule `535ec972`. Built via OrbStack `docker buildx` cross-build (`linux/amd64` via Rosetta); one-time plugin registration required. Runtime is gated on this Mac: OrbStack's kernel exposes no NUMA sysfs / no hugepages on arm64 OR amd64-via-Rosetta, identical to the WSL2 `numa_cnt 0` blocker — `fdctl configure init all` fails at the hugetlbfs stage. A standard-kernel QEMU x86_64 VM (`6.8.0-142-generic`, 16 vCPU, 64 GiB, TCG/no-KVM) exposes `CONFIG_HUGETLBFS=y`/`CONFIG_NUMA=y` and `/sys/devices/system/node/node0`; there `fdctl configure init hugetlbfs` reserves 19969 hugepages and mounts hugetlbfs (exit 0), `configure init sysctl` + `configure check all` exit 0, and `fdctl run` boots the validator: `fd_bootinfo` starts 14 tiles / 39 GiB, the metric tile serves Prometheus, the embedded Agave child parses all argv via clap, initializes its ledger subsystem (creates `accounts/`, `admin.rpc`, `ledger.lock`, `snapshots/`), reaches genesis-config load, and stays alive until the 180s timeout (SIGTERM, not a crash). Two blockers were resolved via config-only toggles (NOT source deviations): `development.sandbox=false` (seccomp/CLONE_NEWUSER/CLONE_NEWPID killed waker:0+metric:0 tiles via SIGSYS on clock_nanosleep) and `[rpc] only_known=false` (`default.toml`'s `only_known=true` made `agave_boot` emit `--only-known-rpc`, whose clap `.requires("known_validators")` rejected the empty bootstrap list). A Firedancer (Frankendancer) node was also deployed as a **real Kurtosis container** (Kurtosis CLI/engine 1.20.0 on jiema's OrbStack socket, isolated from the other user's Docker; enclave `fd-firedancer`, service `firedancer`). The build-evidence path (`firedancer-single-node.star`, `cmd=['version']`) succeeded in-container — `fdctl version`/`solana --version` captured — honest `built` in a Kurtosis container. The real-run probe (`firedancer-realrun-probe.star`, 5 stages via `plan.exec`) captured the exact blocker: `fdctl configure init all` exit 1 at `fd_numa_linux.c(50)` `opendir('/sys/devices/system/node')` ENOENT + `fd_cpu_topo.c(17)` `fopen('/sys/devices/system/cpu/cpu1/online')` ENOENT. This is the same OrbStack kernel-config absence (no NUMA/hugepages sysfs) — not a privilege issue; no `--privileged`/sysctl/Kurtosis cap creates sysfs the kernel does not expose. The fork's NUMA-fabrication fallback synthesizes node 0 but `fd_cpu_topo.c` separately requires `cpuN/online` and fails first. So: `built` in Kurtosis; run path BLOCKED at the kernel gate.

Honest ceiling on this host: `started` (research-grade, Frankendancer, TCG, **genesis-load resolved**) via the standalone QEMU VM; `built` in a real Kurtosis container (run path BLOCKED at the OrbStack kernel gate). The genesis-load blocker that capped the prior `started` evidence (which stopped at `open.rs(25)` "Unable to open genesis.bin") is **resolved**: a `genesis.bin` (1,462,232 bytes) was generated via `solana-test-validator` from a `solana-diff/agave-tools:4.3.0-amd64` image built from the prebuilt official Agave v4.3.0 release tarball (no Rust compile), pushed into the qcow2, and loaded by the embedded Agave. Key discovery: Rosetta does NOT expose AVX (solana-test-validator aborts in-container), but QEMU `-cpu max` does (AVX/AVX2). With the genesis present, the embedded Agave progressed **past** genesis load into blockstore/RocksDB init (`blockstore_db.rs(211)`) and bank-fork init (`bank_forks_utils.rs(124)`), and the ledger dir shows `accounts/` + `rocksdb/` created — proof of account/bank processing. `joined`/`voting` remain unreachable under TCG (too slow for slot cadence; last log line is bank-fork init, no bank-frozen/leader/gossip/RPC before the 240s timeout). The `solana-test-validator` was used ONLY as a genesis generator (its genesis construction is `create_genesis_config_with_leader_ex`, `runtime/src/genesis_utils.rs:533` — NOT the plain `create_genesis_config` helper; see `knowledge/solana-test-validator.md` §6.1), NOT as the validator under test. Evidence: `verification-firedancer-frankendancer.json`, `evidence/firedancer-26094-vm-probe/`, `evidence/firedancer-26094-qemu/20260928T185111Z/`, `evidence/firedancer-26094-qemu/20260929T041000Z-genesis/`, `evidence/firedancer-26094-qemu/20260929T192020Z-kurtosis/`. |
| Solana Labs | `v1.18.26` | yes | no | both genesis directions rejected in local probes |
| Sig | `v0.2.0` (fork) | **no** (observer) | n/a | **`joined` (2026-10-20, strongest); functional-path `started` (2026-10-02); standalone `started` (2026-09-29); cold-start `not_started` (2026-09-30, superseded).** The v0.1.0 stable release is only an RPC library. Current v2 is pinned via the `Alleysira/sig` fork @ `f4ccc97c12535a37bd508252a4040a546ea0b329` on branch `dev/local-observer` (parent `fce80594`, upstream base `b5026c60`), carrying 5 tracked deviation files (`v2/components/snapshot/api.zig`, `v2/lib/solana/cluster.zig`, `v2/main.zig`, `v2/services/shred_receiver.zig`, `v2/services/snapshot.zig`) + `DEVIATIONS.md` — NOT byte-identical to upstream. Deviations add a `.development` cluster path (manual entrypoints, `shred_version` config, `skip_on_cold_start` snapshot bypass) and bound the shred_receiver's accepted slot range to the snapshot slot; public-cluster behavior remains byte-identical. **`joined` (2026-10-20):** rebuilt as `solana-diff/sig:v0.2.0-arm64-functional` (id `sha256:ada6de25ee07`); deviation 5 fixed the replay `OutOfSpace` root cause (the shred_receiver read the snapshot slot then discarded it — `_ = slot; // TODO` — and never bounded its accepted range, so live-tip orphan shreds filled replay's fixed 4096-node, no-eviction forest). With the fix, SIG stayed alive (0 `OutOfSpace`) and replayed real slots (186, 211, 225, 262, 290); the bootstrap's gossip view lists `Nodes: 3` (JitoLabs + Agave + SIG `172.16.0.10`), the authoritative `joined` signal. **Functional path (2026-10-02):** followed the OFFICIAL "running a functional Sig validator" README steps (1-4): real leader schedule from the bootstrap RPC; `skip_on_cold_start=false` → real snapshot (slot 290); `shred-stream` executed inside the bootstrap container. Reached `started` (real shred reception + replay processed real FEC sets) before the (now-fixed) `OutOfSpace` crash. **Standalone (2026-09-29):** the **io_uring gate** was resolved — x86_64/Rosetta `io_uring_setup` returns ENOSYS even under `--privileged` (caps that image at `built`); native arm64 returns EPERM under default seccomp but OK under `--privileged`; all services booted past io_uring. **Cold-start (2026-09-30, superseded):** the `skip_on_cold_start=true` empty-snapshot bypass died at `MissingVersionFile` (`snapshot.zig:554:68`). SIG v2 is a **NON-VOTING OBSERVER** (never votes; no vote/stake accounts in Config — structurally impossible; README says "Sig v2 is not yet a complete validator"). Evidence: `joined` `evidence/multiclient-20261020T061409Z/summary.json`; functional-path `evidence/multiclient-20261001T192451Z/summary.json`; standalone `evidence/sig-v02-qemu/20260929T160325Z-kurtosis-privileged/`; superseded cold-start `evidence/multiclient-20260930T104821Z/summary.json`. |

## What is verified

**Jito+Agave+SIG `joined` run (2026-10-20, strongest SIG evidence).** A Jito
bootstrap validator, an Agave joiner validator, and a SIG observer ran together
in ONE Kurtosis enclave (`solana-multiclient`, `kurtosis run --privileged`) on a
shared genesis (hash `5cTNxfRAC9C4MYBZb93Y5RR8pnVHJ8QDVtzrRe3Yacm9`, shred
version 678). Both voting validators were non-delinquent (bootstrap JitoLabs
`6NcwUAG2…` 50%, joiner Agave `4Trs56yw…` 50%, both `4.3.0`); slots advanced
949→987 (38, exceeding the 20 target); a cross-node finalized 1 SOL transfer was
confirmed (signature `2G9wLFpv7R2QpsKjxwFjPBeaLLSxjDMgeCHA2P77Vu4LDFme4aLLLkGQF1UdPRkdoxF4LJHY4VTLtix7eNzAVxm5`).
**The SIG v2 observer reached `joined`** — the bootstrap's `solana gossip` view
lists `Nodes: 3`: the two voting validators AND the SIG observer
(`172.16.0.10`, identity `xhXMUacm…`). This is the authoritative `joined` signal
per AGENTS.md (a peer sees SIG in the shared-genesis gossip view). The SIG
observer's replay `OutOfSpace` bug is **FIXED** (deviation 5,
`Alleysira/sig@f4ccc97c`): SIG's `shred_receiver` previously read the snapshot
slot then discarded it and never bounded its accepted slot range, so every shred
was accepted; live-tip orphan shreds filled replay's fixed 4096-node,
no-eviction forest and replay exited. The fix bounds the accepted window to
`[snapshot_slot, snapshot_slot+96]`; the package also feeds `shred-stream` a
bounded window from SIG's snapshot slot. SIG stayed alive with **0 `OutOfSpace`**
and replayed real slots (186, 211, 225, 262, 290). SIG is a NON-VOTING OBSERVER
(never votes; no vote/stake accounts — structurally impossible). This is a TWO
voting-validator run (Jito + Agave) plus one SIG observer, not a five-client
testnet. Evidence: `evidence/multiclient-20261020T061409Z/summary.json`.

**Functional-path Jito+Agave+SIG run (2026-10-02).** A Jito bootstrap
validator, an Agave joiner validator, and a SIG observer ran together in ONE
Kurtosis enclave (`solana-multiclient`, `kurtosis run --privileged`) on a
shared genesis (hash `CH1ACyLKwnfUkmY9yUCUNUR1SbXit9nsH7vMbr1jDrLK`, shred
version 24319, slot-0 bank hash captured). Both voting validators were
non-delinquent (bootstrap JitoLabs `E7hVq7Jx…` 50%, joiner Agave `BQYBGMdg…`
50%, both `4.3.0`); slots advanced 14926→14964 (39, exceeding the 20 target);
a cross-node finalized transfer was confirmed (signature
`4EdnjD2QbX6WiiCX21Ln67V3ggMF2pYLd1gNLtiKUhhyoLzunLwsC2NN7qrjg5jgGnKRC7N6FzF4R4cmFmfyLmCc`,
recipient `GLcNjrcdDJca3ci9udgxqEnucGu7a6ih2uurs3hiwfr4`, 8 SOL).
`solana validators` "Stake By Client ID" enumerates `JitoLabs` and `Agave` as
separate clients — proven client diversity, though Agave and Jito share
substantial code, so this is a two-implementation agreement, not an
independent majority oracle. The SIG observer
(`solana-diff/sig:v0.2.0-arm64-functional`, deviated fork @ `fce80594` on
`dev/local-observer`) followed the OFFICIAL "running a functional Sig
validator" README steps (1-4): real leader schedule extracted from the
bootstrap RPC via `solana leader-schedule`; `skip_on_cold_start=false` → real
snapshot downloaded from the bootstrap (slot 290); `sig config.zon` started;
`shred-stream --ledger <bootstrap-ledger> --target <sig-ip>:8002 --rate-hz 100`
executed inside the bootstrap container. SIG reached strictly stronger
`started` than the prior cold-start `not_started`: accounts_db started + real
shred reception (32 InvalidSignature + 32 BadSlotOrParentOffset warnings) +
replay service received real FEC sets (slots 277, 3001, 2455) before replay
crashed with `OutOfSpace` at `pool.zig:280` / `replay.zig:830`
(`insertFecSet`) / `replay.zig:227` (`serviceMain`). Honest SIG level for this
run: `started` (received real shreds + replay processed real FEC sets before
the crash), NOT `joined` (replay crashed). Root cause (refinement, NOT a gate
for the 20-slot goal): shred-stream fed shreds from slot 0, but SIG's snapshot
base is slot 290; the README says to feed "all slots starting at the snapshot
slot." The 20 slots came from the two voting validators (Jito + Agave); the
enclave was then stopped and removed. See
`evidence/multiclient-20261001T192451Z/summary.json`. This is a TWO
voting-validator run (Jito + Agave) plus one SIG observer, not a five-client
testnet.

**First mixed-client Jito+Agave+SIG run (2026-09-30).** A Jito bootstrap
validator and an Agave joiner validator ran together in ONE Kurtosis enclave
(`solana-multiclient`, `kurtosis run --privileged`) on a shared genesis
(`6Vum9Njd…`, shred version 45836, bank hash `8GnKd1fp…`). Both were
non-delinquent voting validators (Last Vote 336, Root Slot 305, Credits 1312,
0.00% skip, 99.997717120 SOL / 50.00% stake each); slots advanced 294→329
(35, exceeding the 20 target); a 1 SOL transfer submitted on the bootstrap
was observed at finalized commitment on the joiner (signature `PVZgW5hTp…`,
recipient 1000000000 lamports). `solana validators` "Stake By Client ID"
enumerates `Agave - 1 current validators (50.00%)` and
`JitoLabs - 1 current validators (50.00%)` as separate clients — proven client
diversity, though Agave and Jito share substantial code, so this is a
two-implementation agreement, not an independent majority oracle. A SIG
observer (`solana-diff/sig:v0.2.0-arm64-dev`, deviated fork @ `5815597b`) was
launched alongside them; its patched cold-start bypass reached gossip +
shred_receiver + accounts_db-start, but `accounts_db` then exited with
`MissingVersionFile` (`snapshot.zig:554:68`) — honestly recorded as
`not_started`, NOT a gate for the 20-slot goal (the two voting validators
produced the slots). This SIG `not_started` is **superseded** for the SIG
functional-path question by the 2026-10-02 run above; the voting-validator
evidence (slots 294→329, client diversity) remains valid and is itself
superseded only in slot count, not in client-diversity conclusion. The enclave
was then stopped and removed. See `evidence/multiclient-20260930T104821Z/summary.json`.
This is a TWO voting-validator run (Jito + Agave) plus one SIG observer, not
a five-client testnet.

Jito-Solana ran as a real voting validator, advanced slots, and finalized a
1 SOL transfer. The container ran without privilege, Linux capabilities, or
`no-new-privileges`/seccomp exceptions. See `verification-jito430.json`.

The shared-genesis harness also cold-started two independent Jito validators
with distinct identity, vote, stake, and BLS keys. Both nodes reported the same
genesis hash, appeared in the gossip table, became non-delinquent voting
validators, advanced slots, and observed a 1 SOL transfer at finalized
commitment through different RPC nodes. See `verification-shared-genesis.json`
(now marked `superseded` for the client-diversity question by the 2026-09-30
mixed-client run above — retained, not deleted). This validates the multi-node
orchestration, not client diversity: both binaries identify themselves as
`JitoLabs` and use the same immutable image.

Agave `solana-test-validator` 4.3.0 passed RPC, WebSocket, finalized transfer,
and program execution checks, and the full `agave-validator` later voted as the
joiner in the 2026-09-30 mixed-client run above.

## Why five latest-stable validators cannot be claimed

Solana Labs 1.18 and the current 4.3 family disagree about the genesis/vote
account representation. Disabling features did not resolve this: each genesis
direction failed before normal voting could begin.

Sig's v0.1.0 stable tag contains an RPC library, not a validator executable.
Current Sig `main` (v2, pinned via the `Alleysira/sig` fork @ `fce80594` on
branch `dev/local-observer`, parent `b5026c60` via `5815597b`, carrying 4
tracked deviation files + `DEVIATIONS.md` — NOT byte-identical to upstream)
builds as a Zig 0.15.2 validator-observer and has been **started** three ways:
standalone in a real Kurtosis container on this host (native arm64 +
`--privileged`, io_uring gate resolved, 2026-09-29); in the 2026-09-30
mixed-client cold-start (`not_started` — `accounts_db` exited with
`MissingVersionFile` at `snapshot.zig:554:68`, superseded); and on the
**functional path** (2026-10-02, strongest) following the OFFICIAL README
steps — real leader schedule + real snapshot (slot 290) + real shred stream
fed by `shred-stream` inside the bootstrap container — reaching accounts_db
started + real shred reception + replay FEC sets (slots 277, 3001, 2455)
before replay crashed with `OutOfSpace` (`pool.zig:280` / `replay.zig:830` /
`replay.zig:227`). The crash is a refinement opportunity (feed only slots ≥
the snapshot slot, per the README), NOT a gate for the 20-slot goal. Upstream
still calls it incomplete: it requires an externally generated leader schedule
and a complete shred stream (no repair), and it **does not vote** — so it
deploys only as a **non-voting observer**, never a fifth voting validator.

## Executable next milestone

1. ~~Re-run the verified shared-genesis harness with the full Agave image as
   `JOINER_IMAGE`.~~ **DONE (2026-09-30):** the mixed-client Jito+Agave+SIG run
   proved Agave/Jito client diversity (both voting, 35 slots ≥ 20, cross-node
   finalized transfer, `Stake By Client ID` Agave+JitoLabs separate). See
   `evidence/multiclient-20260930T104821Z/`.
2. ~~Resolve the SIG cold-start `accounts_db` `MissingVersionFile` blocker
   (`snapshot.zig:554:68`) so the observer can reach `joined` alongside the
   voting validators — a snapshot-feed path (bootstrap-produced snapshot + real
   shred stream), not a relaxation of the non-voting rule.~~ **PARTIALLY DONE
   (2026-10-02):** the functional path now feeds SIG a real leader schedule +
   real snapshot (slot 290) + real shred stream per the OFFICIAL README steps;
   SIG reaches `started` (accounts_db started, real shred reception, replay
   processed real FEC sets) before replay crashes with `OutOfSpace`. The
   `MissingVersionFile` cold-start blocker is resolved (superseded). The
   remaining refinement to `joined`: feed only slots ≥ the snapshot slot (290)
   per the README's "all slots starting at the snapshot slot" guidance, so the
   replay FEC-set pool does not overflow with mismatched early shreds.
3. Repeat Firedancer 26.09.4 component and runtime validation on a dedicated
   Linux x86_64 host with NUMA nodes exposed and at least 128 GiB physical RAM
   (the release reports a ~109 GiB testnet footprint). Review the five tracked
   conversion fixes with upstream before calling the build clean. Use
   `deploy/firedancer/` for the preflight and host deployment boundary.
4. Choose one relaxation for each upstream conflict: use a protocol-compatible
   Solana Labs revision instead of latest stable, and use Sig `main` as a
   non-voting observer—or wait for an upstream complete stable Sig validator.

The package must not label an observer, RPC library, or aliased Agave process
as a distinct voting client merely to reach a count of five.
