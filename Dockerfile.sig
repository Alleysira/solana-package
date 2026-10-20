# syntax=docker/dockerfile:1
#
# SIG v2 (Zig Solana validator) — container build.
#
# ──────────────────────────────────────────────────────────────────────────
# WHAT THIS IS (recorded honestly per AGENTS.md evidence rules)
# ──────────────────────────────────────────────────────────────────────────
# SIG (https://github.com/Syndica/sig) is a Solana validator client written in
# Zig.  The v2 implementation (root build.zig.zon, version "0.2.0") is a
# multi-process architecture: each service (gossip, shred_receiver, snapshot,
# accounts_db, replay, exec, telemetry, net) runs in its own sandboxed process
# and communicates through typed shared-memory regions.
#
# SIG v2 is NOT a complete voting validator.  Per the upstream README and
# source inspection (2026-09-29):
#   - It requires an externally generated leader schedule (solana leader-schedule)
#   - It requires a snapshot from another validator
#   - It does NOT implement repair, so it needs a complete external shred stream
#   - It does NOT vote (no vote/stake accounts in its config)
# It is therefore a NON-VOTING OBSERVER, never a voting validator.  Any
# deployment must be described as "N validators plus one SIG observer", never
# as N+1 voting validators (per AGENTS.md acceptance criteria).
#
# ──────────────────────────────────────────────────────────────────────────
# SOURCE PIN (provenance, per AGENTS.md)
# ──────────────────────────────────────────────────────────────────────────
# The workspace `sig` submodule is pinned to the user's fork, on the
# `dev/local-observer` branch:
#   github.com/Alleysira/sig @ f4ccc97c12535a37bd508252a4040a546ea0b329
# Upstream base: b5026c60fe56b51edd79131115b7e741449d6b2e (byte-identical to
# upstream Syndica/sig main; verified an ancestor of HEAD).  This branch
# (dev/local-observer) CARRIES TRACKED DEVIATION FILES (5 source files +
# DEVIATIONS.md, across one or more deviation commits on top of the base) so
# SIG v2 can join an isolated local cluster as a non-voting observer (see
# DEVIATIONS.md in the fork).  Mirrors the provenance discipline of the
# `Alleysira/firedancer` fork (6 tracked deviation files).  A build from this
# pin is NOT a clean upstream build — record the deviation explicitly.
# Deviation files (5 source + DEVIATIONS.md):
#   v2/lib/solana/cluster.zig              — add `.development = 3` cluster value
#   v2/main.zig                            — manual ClusterInfo + config plumbing
#   v2/components/snapshot/api.zig         — skip_on_cold_start field
#   v2/services/snapshot.zig               — cold-start snapshot bypass
#   DEVIATIONS.md                           — provenance
#
# ──────────────────────────────────────────────────────────────────────────
# ARCHITECTURE / BUILD TARGET
# ──────────────────────────────────────────────────────────────────────────
# SIG v2 CI runs ONLY on x86_64 Linux (target x86_64-linux-gnu.2.36, see
# .github/workflows/check_linux.yml).  v2 has NO macOS/arm64 CI.  This image
# therefore cross-builds as linux/amd64 via OrbStack Rosetta, matching the
# upstream CI target exactly and the proven Firedancer cross-build pattern.
#
# AVX / SHA concern (resolved):
#   - `-Dallow-no-avx512`: opts into a slower generic ed25519 path (no AVX-512
#     avx512ifma+avx512vl).  Without this flag, building for an x86_64 target
#     lacking AVX-512 is a compile-time ERROR.
#   - `-Dallow-no-sha`: opts into a slower software SHA fallback when the
#     target lacks the x86 SHA-NI extension.
#   - Rosetta's amd64 emulation lacks AVX/AVX-512/SHA-NI.  These flags select
#     the software fallbacks, so the *output binary* does not hard-require AVX.
#   - This is different from solana-test-validator, which detected missing AVX
#     at RUNTIME and panicked.  SIG's fallbacks are compile-time selections.
#
# Zig's x86_64-linux baseline (SSE2) is the lowest common denominator; with
# both allow-flags the binary should run on any x86_64 CPU, including Rosetta.
#
# ──────────────────────────────────────────────────────────────────────────
# RUNTIME CONTRACT
# ──────────────────────────────────────────────────────────────────────────
# The sig binary takes:  sig <config.zon> [log_filters]
#   - argv[1] = path to a .zon config file (errors ConfigPathMissing if absent)
#   - argv[2] = optional log filter string
# The config requires: cluster, leader_schedule_file, gossip/shred/telemetry
# ports, snapshot folder, accounts_db file.  See config/example.zon.
#
# SIG does NOT have a --version or --help flag.  Build evidence = the binary
# builds and executes (returns a deterministic error when given no config).
#
# Honest evidence ceiling on this Mac: `built` (binary builds + executes).
# `started` requires a reachable gossip entrypoint (getFromEcho), a 432000-slot
# leader schedule, and a snapshot — none of which exist on this host without a
# running cluster.  `joined` needs another node's gossip view.  `voting` is
# structurally impossible (SIG never votes).

ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

# ──────────────────────────────────────────────────────────────────────────
# BUILD TARGET (parameterized — see SIG_TARGET / SIG_RUNTIME_PLATFORM below)
# ──────────────────────────────────────────────────────────────────────────
# Two supported targets, chosen at build time:
#
#   1. x86_64-linux-gnu.2.36  + linux/amd64   (DEFAULT — matches upstream CI)
#      Honest ceiling on this Mac: `built`.  Why: OrbStack's Rosetta amd64
#      syscall-translation layer does NOT translate io_uring_setup (syscall
#      425) — it returns ENOSYS under default, seccomp=unconfined, AND
#      --privileged (verified 2026-09-29), even though __arm64_sys_io_uring_*
#      ARE in /proc/kallsyms.  Zig's IoUring.zig:62 maps .NOSYS =>
#      error.SystemOutdated, so accounts_db crashes at init.  This is a
#      Rosetta syscall-translation gate, NOT a seccomp gate and NOT a missing
#      kernel feature — not solvable by privilege.  This target is the one
#      upstream CI uses, so it is the primary `built`-evidence target.
#
#   2. aarch64-linux-gnu.2.36  + linux/arm64   (native — runtime-capable here)
#      Honest ceiling on this Mac: `started` (under --privileged).  Why: a
#      NATIVE arm64 container hits only the DEFAULT container seccomp profile,
#      which blocks io_uring_setup with EPERM — and `--privileged` /
#      `seccomp=unconfined` clears it (io_uring_setup OK, features=0x3ffff,
#      verified 2026-09-29).  ALL services then boot: config parse, 19
#      shared-memory regions, net binds 8001+8002, gossip STARTS (real
#      identity, shred_version=4457, testnet entrypoints), shred_receiver
#      waits, snapshot starts, accounts_db starts past io_uring (writes
#      journal, reads from snapshot).  Next gate: net sendto => WouldBlock
#      (gossip to unreachable testnet entrypoints) — the expected cluster
#      gate, not a host gate.  SIG v2 builds clean for arm64 even though its
#      CI is x86_64-only (verified).  This is a recorded target-architecture
#      deviation (arm64 vs CI x86_64), NOT a source deviation — the fork
#      stays byte-identical to upstream.
#
# The builder ALWAYS runs natively on linux/arm64 ($BUILDPLATFORM) to avoid
# the Zig 0.15.2 build_runner PRNG mis-emulation under Rosetta (see below);
# -Dtarget then selects the output arch (cross-compile for x86_64, native for
# aarch64).  The runtime stage platform MUST match the binary's target arch.
ARG SIG_TARGET=x86_64-linux-gnu.2.36
ARG SIG_RUNTIME_PLATFORM=linux/amd64

# ──────────────────────────────────────────────────────────────────────────
# BUILDER runs NATIVELY on linux/arm64 (no Rosetta), -Dtarget selects output arch
# ──────────────────────────────────────────────────────────────────────────
# WHY NATIVE ARM64 BUILDER: under Rosetta (linux/amd64 builder), the Zig
# 0.15.2 build_runner's PRNG mis-emulates — `constructGraphAndCheckForDependencyLoop`
# → `shuffleWithIndex` panics with "index out of bounds: index 31, len 31"
# DETERMINISTICALLY (reproduced with seeds 0x6d3244c9 and 0xe098cf9d; SIG's
# native x86_64 CI passes, so the bug is Rosetta mis-emulation of the PRNG,
# not SIG source).  Running the build_runner as native arm64 code avoids the
# mis-emulation, and `zig cc` still cross-compiles all C deps to whichever
# -Dtarget is selected.  Verified 2026-09-29 for BOTH targets: a native-arm64
# Zig 0.15.2 build produces a working ELF binary that executes (x86-64 returns
# ConfigPathMissing on linux/amd64; aarch64 boots all services under
# --privileged on linux/arm64).
# Note: --platform=$BUILDPLATFORM forces the builder to run on OrbStack's
# NATIVE arm64 (no Rosetta) regardless of the final --output platform, so the
# build_runner PRNG does not mis-emulate.  $BUILDPLATFORM is the host arch
# buildx sets for cross-builds.
FROM --platform=$BUILDPLATFORM ${DEBIAN_IMAGE} AS builder
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Re-declare the global ARGs (declared above the first FROM) so they are in
# scope for the RUN steps in THIS stage.  Global ARGs are only available for
# FROM resolution, not inside stages, unless re-declared here.
ARG SIG_TARGET
ARG SIG_RUNTIME_PLATFORM

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git python3 \
    && rm -rf /var/lib/apt/lists/*

# ── Install Zig 0.15.2 for the BUILDER's native arch (aarch64-linux) ───────
# We use the aarch64-linux Zig so the build_runner runs as native arm64 code
# (no Rosetta PRNG mis-emulation).  It still cross-compiles the output to
# x86_64-linux-gnu.2.36 via -Dtarget.  Pinned tarball + sha256.
# Source: https://ziglang.org/download/index.json (fetched 2026-09-29)
ARG ZIG_VERSION=0.15.2
ARG ZIG_TARBALL_URL=https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz
ARG ZIG_TARBALL_SHA256=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f

RUN curl -fsSL "$ZIG_TARBALL_URL" -o /tmp/zig.tar.xz \
    && echo "${ZIG_TARBALL_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH

# ── Acquire source by cloning the pinned fork at the immutable commit ─────
# Same pattern as Dockerfile.firedancer: the submodule .git is a gitdir pointer
# whose object database lives outside the copied subtree, so COPY fails.  We
# clone from the fork URL and checkout the pinned commit.  build-sig.sh still
# pre-verifies the local submodule pin matches before this build starts.
ARG SIG_FORK_URL=https://github.com/Alleysira/sig.git
ARG SIG_COMMIT=f4ccc97c12535a37bd508252a4040a546ea0b329

RUN git clone "$SIG_FORK_URL" /src/sig && \
    git -C /src/sig checkout "$SIG_COMMIT"
WORKDIR /src/sig

# Record the exact source state in BUILD-INFO.
RUN test "$(git rev-parse HEAD)" = "$SIG_COMMIT" \
    && printf 'commit=%s\nfork=yes(Alleysira)\nupstream=Syndica/sig\nfork_diff=dev/local-observer branch; 5 tracked deviation files + DEVIATIONS.md (development observer path)\nupstream_base=b5026c60fe56b51edd79131115b7e741449d6b2e(byte-identical-to-upstream-main)\nzig=%s\ntarget=%s\nruntime_platform=%s\nbuild_flags=-Dallow-no-sha -Dallow-no-avx512\nclient=SIG-v2-observer-non-voting\nnote=tracked-deviation-build-see-DEVIATIONS-md\n' \
         "$SIG_COMMIT" "$ZIG_VERSION" "$SIG_TARGET" "$SIG_RUNTIME_PLATFORM" > /tmp/sig-build-info \
    && git -C . log --oneline -1 >> /tmp/sig-build-info

# ── Pre-fetch Zig package dependencies ─────────────────────────────────────
# tools/fetch-zig-deps.py pre-fetches deps (rocksdb, blst, secp256k1, zstd,
# base58, tracy, poseidon) into ~/.cache/zig/p/ to avoid HTTP flakiness during
# `zig build`.  This is the same step the upstream CI runs.
RUN ./tools/fetch-zig-deps.py build.zig.zon || echo "fetch-zig-deps failed; zig build will retry"

# ── Build the sig binary + shred-stream tool (native arm64 builder) ───────
# `zig build` runs the default install step. build.zig:35 wires
# `tools.shred_stream.installStep()` into the default `install` step (and
# build.zig:62 defines the standalone `shred-stream` step), so the default
# build produces BOTH `zig-out/bin/sig` AND `zig-out/bin/shred-stream`. The
# shred-stream tool is required for the official "functional validator" path
# (README §"Running a functional Sig validator" step 4): SIG has no repair, so
# a complete ledger must be streamed into it via
#   shred-stream --ledger <agave-ledger> --target <ip>:8002 --rate-hz 100
# to feed SIG the slots after the snapshot slot. (The prior `zig build sig`
# built ONLY the sig binary — no tools — which left the runtime image without
# shred-stream.)
#
# The builder runs natively on arm64 (no Rosetta) so the build_runner PRNG
# does not mis-emulate (see the builder-stage note above).  -Dtarget selects
# the output arch: x86_64-linux-gnu.2.36 (cross-compile, CI-matching, default)
# or aarch64-linux-gnu.2.36 (native, runtime-capable on this Mac under --priv).
#
# Flags:
#   -Dtarget=$SIG_TARGET            — x86_64-linux-gnu.2.36 (CI) or aarch64-linux-gnu.2.36 (native)
#   -Dallow-no-sha                  — software SHA fallback (no SHA-NI under Rosetta at RUNTIME)
#   -Dallow-no-avx512               — generic ed25519 fallback (no AVX-512 under Rosetta at RUNTIME)
#   --summary all                   — print build summary
#
# All C deps (rocksdb, blst, secp256k1, zstd) are cross-compiled from source
# by `zig cc` to the SIG_TARGET — no native libs needed.
RUN zig build \
      -Dtarget=$SIG_TARGET \
      -Dallow-no-sha \
      -Dallow-no-avx512 \
      --summary all

# Verify BOTH binaries were produced and stage them at fixed paths.  When the
# target is aarch64 (native to this arm64 builder), the binaries CAN be
# executed here; for x86_64 they cannot (exec format error on arm64).  We only
# check they exist + are executable here — the runtime stage + Kurtosis path
# executes them on $SIG_RUNTIME_PLATFORM.
RUN test -x zig-out/bin/sig \
    && test -x zig-out/bin/shred-stream \
    && rm -rf /opt/sig-stage && mkdir -p /opt/sig-stage/bin \
    && cp -a zig-out/bin/sig /opt/sig-stage/bin/sig \
    && cp -a zig-out/bin/shred-stream /opt/sig-stage/bin/shred-stream

# ──────────────────────────────────────────────────────────────────────────
# Runtime stage — $SIG_RUNTIME_PLATFORM (must match the binary's target arch)
# ──────────────────────────────────────────────────────────────────────────
# The runtime platform MUST match the binary's target arch:
#   - linux/amd64  for x86_64-linux-gnu.2.36 (Rosetta; `built` ceiling — io_uring ENOSYS)
#   - linux/arm64  for aarch64-linux-gnu.2.36 (native; `started` ceiling under --privileged)
# The staged sig binary is an ELF executable for GNU/Linux 2.0+ (verified via
# `file` for both arches).  Under OrbStack it executes: the x86-64 build
# returns the deterministic ConfigPathMissing error (`built`); the aarch64
# build boots all services under --privileged (`started`).
FROM --platform=$SIG_RUNTIME_PLATFORM ${DEBIAN_IMAGE} AS runtime
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Re-declare the global ARGs (declared above the first FROM) so they are in
# scope for the LABEL steps in THIS stage.
ARG SIG_TARGET
ARG SIG_RUNTIME_PLATFORM

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates tini \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/sig /var/lib/sig

COPY --from=builder /opt/sig-stage/bin/sig /opt/sig/bin/sig
COPY --from=builder /opt/sig-stage/bin/shred-stream /opt/sig/bin/shred-stream
COPY --from=builder /tmp/sig-build-info /opt/sig/BUILD-INFO
RUN chmod 0755 /opt/sig/bin/sig /opt/sig/bin/shred-stream

ENV PATH=/opt/sig/bin:$PATH
WORKDIR /var/lib/sig

LABEL org.opencontainers.image.source="https://github.com/Alleysira/sig" \
      org.opencontainers.image.upstream="https://github.com/Syndica/sig" \
      org.opencontainers.image.version="v0.2.0-dev" \
      org.opencontainers.image.revision="f4ccc97c12535a37bd508252a4040a546ea0b329" \
      org.opencontainers.image.build="zig-0.15.2-${SIG_TARGET}-allow-no-sha-allow-no-avx512" \
      org.opencontainers.image.runtime_platform="${SIG_RUNTIME_PLATFORM}" \
      org.opencontainers.image.title="SIG v2 (Zig Solana validator, observer/non-voting, dev/local-observer fork)" \
      org.opencontainers.image.note="SIG v2 non-voting observer; fork carries 5 tracked deviation files (dev/local-observer branch) for local-cluster join; parent b5026c60 is byte-identical to upstream; see DEVIATIONS.md"

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/sig/bin/sig"]
