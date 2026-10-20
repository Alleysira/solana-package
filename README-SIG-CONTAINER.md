# SIG v2 (Zig) container — build, runtime, and honest evidence contract

## What this is

SIG (`https://github.com/Syndica/sig`) is a Solana validator client written in
Zig.  This container path builds the **v2** implementation (root `build.zig.zon`,
version `"0.2.0"`) — a multi-process architecture where each service (gossip,
shred_receiver, snapshot, accounts_db, replay, exec, telemetry, net) runs in
its own sandboxed process and communicates through typed shared-memory regions.

### SIG v2 is a NON-VOTING OBSERVER — never a voting validator

Per the upstream README and source inspection (2026-09-29), SIG v2:

- requires an **externally generated leader schedule** (`solana leader-schedule`)
- requires a **snapshot** from another validator
- does **NOT implement repair**, so it needs a **complete external shred stream**
- does **NOT vote** (no vote/stake accounts in its config; `Config` has no vote
  field)

Any deployment must be described as **"N validators plus one SIG observer"**,
never as N+1 voting validators (per `AGENTS.md` acceptance criteria).  This is
the same observer role the five-client plan documents for SIG.

## Source pin (provenance)

The workspace `sig` submodule is pinned to the user's fork:

```
github.com/Alleysira/sig @ b5026c60fe56b51edd79131115b7e741449d6b2e
```

Verified 2026-09-29: this fork commit is **byte-identical to upstream
`Syndica/sig` main** (empty `git diff`).  Unlike the Firedancer fork
(`Alleysira/firedancer` @ `ff881b69`, which carries 6 tracked deviation files),
the SIG fork carries **ZERO deviation files** — a build from this pin is a
**clean upstream build**.  The fork is still pinned by URL + immutable commit
per the `AGENTS.md` provenance rule.

## Build target and architecture

SIG v2 CI runs **only on x86_64 Linux** (target `x86_64-linux-gnu.2.36`, see
`.github/workflows/check_linux.yml`); v2 has **no macOS/arm64 CI**.  This image
cross-builds as **linux/amd64 via OrbStack Rosetta**, matching the upstream CI
target exactly and the proven Firedancer cross-build pattern.

### AVX / SHA extensions (resolved)

SIG's build has two flags for CPUs lacking x86 SIMD extensions:

- `-Dallow-no-avx512`: opts into a slower **generic ed25519 path** (no AVX-512
  `avx512ifma`+`avx512vl`).  Without this flag, building for an x86_64 target
  lacking AVX-512 is a **compile-time error**.
- `-Dallow-no-sha`: opts into a slower **software SHA fallback** when the target
  lacks the x86 SHA-NI extension.

Rosetta's amd64 emulation lacks AVX/AVX-512/SHA-NI.  These flags select the
software fallbacks, so the **output binary does not hard-require AVX**.

> This is different from `solana-test-validator`, which detected missing AVX at
> **runtime** and panicked ("missing AVX support").  SIG's fallbacks are
> **compile-time** selections — once built with the allow-flags, the binary
> runs on any x86_64 CPU, including Rosetta's emulation.

Zig's `x86_64-linux` baseline (SSE2) is the lowest common denominator; with
both allow-flags the binary should run on any x86_64 CPU.

Build flags (matching upstream CI):
```
zig build sig \
  -Dtarget=x86_64-linux-gnu.2.36 \
  -Dallow-no-sha \
  -Dallow-no-avx512 \
  --summary all
```

Zig version: **0.15.2** (tarball sha256
`02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239`, from
`https://ziglang.org/download/index.json`).

All C deps (rocksdb, blst, secp256k1, zstd) are vendored via Zig's `git+https://`
package manager and compiled from source by `zig cc` for the target — no
apt-installed native libraries needed.

## Runtime contract

The `sig` binary takes: **`sig <config.zon> [log_filters]`**

- argv[1] = path to a `.zon` config file (errors `ConfigPathMissing` if absent)
- argv[2] = optional log filter string

SIG does **NOT** have a `--version` or `--help` flag.  **Build evidence = the
binary builds and executes** (returns a deterministic error when given no
config).

The config (`config/example.zon`) requires: `cluster`, `leader_schedule_file`,
`gossip`/`shred_network`/`telemetry` ports, `snapshot` folder, `accounts_db`
file.  Two sandboxing modes:

- `sandboxed`: forks child processes + installs seccomp BPF filters +
  `SET_NO_NEW_PRIVS`.  Can fail under container seccomp profiles.
- `threaded`: single-process, threads.  Container-friendly.  Use this for the
  observer probe.

The leader schedule parse (`LeaderSchedule.fromCommand`) requires **exactly
432000** contiguous `<slot> <pubkey>` lines (`slots_per_epoch = 432000`).

`getFromEcho` connects to cluster gossip entrypoints via TCP — on this host no
cluster is reachable.

## Honest evidence levels on this Mac

| Level | Reachable? | Reason |
| --- | --- | --- |
| `researched` | yes | source + upstream docs inspected |
| `prepared` | yes | Dockerfile/build-script/Kurtosis package written |
| `built` | yes | binary builds + executes (x86_64 image on linux/amd64 via Rosetta; arm64 image on linux/arm64 native) |
| `started` | **yes** | **PROVEN 2026-09-29** in a real Kurtosis container: native arm64 image + `--privileged` boots all services past config parse AND past the io_uring gate (gossip starts, accounts_db starts). x86_64/Rosetta image caps at `built` (io_uring ENOSYS). |
| `joined` | no | needs another node's gossip view (no reachable cluster on this Mac) |
| `voting` | **never** | SIG v2 has no vote/stake accounts; structurally impossible |
| `end-to-end` | no | no voting, no tx confirmation |
| `differential` | not in this run | component differential is a separate campaign |

Honest ceiling on this host: **`started`** (native arm64 + `--privileged`,
inside a real Kurtosis container).  `joined` requires a reachable gossip
entrypoint, a real snapshot, and a complete shred stream — none of which exist
without a running cluster.  **`voting` is structurally impossible** (SIG never
votes).

**Unlike Firedancer, SIG has NO NUMA/hugepage kernel gate** — it is a normal
Zig process.  The OrbStack kernel gate that blocks Firedancer does NOT apply.
SIG's only host gate is the io_uring gate, and it is **solvable** (unlike
Firedancer's NUMA gate): native arm64 + `--privileged` clears it.

## Files

- `Dockerfile.sig` — two-stage build (builder clones fork @ pinned commit,
  installs Zig 0.15.2, builds `zig build sig` with allow-flags, stages binary;
  runtime stage copies binary + BUILD-INFO).
- `build-sig.sh` — build script: source-pin verification (rejects dirty tree),
  disk/memory floor gates, Rosetta cross-build via
  `docker --context orbstack buildx build --platform linux/amd64 --load`,
  build-evidence check (runs binary with no config).
- `kurtosis/sig-single-node.star` — Kurtosis package: build-evidence path
  (default) + real-run path (needs cluster).
- `kurtosis/sig-realrun-probe.star` — Kurtosis probe: captures exactly where
  `sig config.zon` lands on this host (expected: config parse OK, then
  gossip/snapshot gate).

## Usage

Build:
```bash
cd solana-package
export DOCKER_HOST=unix:///Users/jiema/.orbstack/run/docker.sock
./build-sig.sh
```

Kurtosis build-evidence deployment:
```bash
export DOCKER_HOST=unix:///Users/jiema/.orbstack/run/docker.sock
export PATH="/Users/jiema/.local/bin:$PATH"
kurtosis enclave stop sig-observer || true
kurtosis enclave rm sig-observer || true
kurtosis run --enclave sig-observer ./kurtosis/sig-single-node.star
```

Kurtosis real-run probe (captures the host gate):
```bash
kurtosis run --enclave sig-observer ./kurtosis/sig-realrun-probe.star
```

## What is NOT proven

- No voting, no end-to-end, no differential evidence.
- No `joined`/`started` claim on this host (no reachable cluster, no snapshot,
  no shred stream).
- The fork is byte-identical to upstream, so this is a clean build — but the
  build still targets linux/amd64 via Rosetta (the upstream CI arch), not the
  host's native arm64.
