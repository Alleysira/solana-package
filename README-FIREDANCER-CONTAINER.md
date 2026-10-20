# Firedancer (Frankendancer) container build

This documents the container/Kurtosis path for the Firedancer target on this
Mac Studio. Read it alongside `AGENTS.md` (evidence rules) and
`Dockerfile.firedancer` (the source-deviation inventory).

## What this builds (recorded honestly)

The official Firedancer Getting Started guide
(docs.firedancer.io/guide/getting-started.html, inspected 2026-09-28) states
verbatim that `v26.09.4` is the **Frankendancer** (Agave hybrid) build target
and that "It is not yet possible to run a full Firedancer validator, which is
in heavy development." This container therefore builds the **Frankendancer**
path (`fdctl` + `solana` CLI), which is the official docs' recommended target.

This is an **explicit, recorded relaxation** of AGENTS.md's "full Firedancer,
NOT Frankendancer" rule, made after inspecting the official docs and with the
user's recorded choice.

## Source pin (a fork, not upstream)

The workspace `firedancer` submodule is pinned to a **fork**,
`github.com/Alleysira/firedancer @ ff881b69a93a6519c1a6f09698aaf208753a0a8f`
("fix WSL component build conversions and NUMA fallback"), which layers **6
tracked deviation files** on top of upstream parent `39bc5a27b`:

1. GCC-12 conversion casts in `fd_forest.h`
2. GCC-12 conversion casts in `fd_tar.h`
3. GCC-12 conversion casts in `fd_rserve_tile.c`
4. GCC-12 conversion casts in `fd_zstd_frame.c`
5. GCC-12 conversion casts in `fd_ssmanifest_parser.c`
6. `fd_numa_linux.c` NUMA-fabrication fallback

Files 1–5 are needed to pass `-Werror` under GCC 12 (upstream CI uses GCC
12.4.0 and passes clean). File 6 is a **topology fabrication** — when
`/sys/devices/system/node` is absent it returns one synthetic node and maps
every CPU to node 0. **The NUMA fallback is invalid for runtime memory sizing
or any validator/network claim.** It is committed in the fork so it is visible
in the image's `BUILD-INFO`, never hidden.

`build-firedancer.sh` pre-verifies the local submodule pin matches
`ff881b69` and the Agave submodule pin matches
`535ec972e6f0037b6a4c5a5e98cff4597781e678` before building (a fail-fast
provenance gate). The Dockerfile then **clones the fork at the immutable
commit** rather than COPYing the workspace submodule — see "Why clone, not
COPY" below.

## Build on this Mac Studio

The build runs under **OrbStack amd64 emulation (Rosetta)** to produce a real
`linux/amd64` image. Two one-time setup steps are required:

### 1. Register the buildx plugin (one-time)

OrbStack's `docker` CLI (v29.4.0) ships **without** the `buildx` subcommand.
Plain `docker build --platform linux/amd64` does **not** cross-build on
OrbStack — `RUN` steps execute natively as arm64, producing arm64 images
(verified). Register OrbStack's bundled `docker-buildx` as a cli-plugin:

```bash
mkdir -p ~/.docker/cli-plugins
ln -sf /Applications/OrbStack.app/Contents/MacOS/xbin/docker-buildx \
       ~/.docker/cli-plugins/docker-buildx
docker --context orbstack buildx version   # should print buildx v0.33.0
```

Then the cross-build command (used by `build-firedancer.sh`) produces real
`linux/amd64` images:

```bash
docker --context orbstack buildx build \
       --builder orbstack --platform linux/amd64 --load \
       --file Dockerfile.firedancer \
       --tag solana-diff/firedancer:v26.09.4-frankendancer-amd64 .
```

### 2. Build

```bash
cd solana-package
./build-firedancer.sh
```

`build-firedancer.sh` enforces disk (≥ ~8 GiB free) and memory (≥ ~4 GiB
inactive) safety floors and cancels early under pressure (the goal: stop the
service early and report, not exhaust the host).

### Why clone, not COPY

The firedancer submodule's `.git` is a **gitdir file**
(`gitdir: ../.git/modules/firedancer`) whose target — the parent repo's
`.git/modules/firedancer/` object database — lives **outside** the firedancer
subtree. `COPY --from=firedancer_source / /src/firedancer/` copies the `.git`
file but not the object database it points at, so `deps.sh fetch` (which runs
`git submodule update --init`) failed with
`fatal: not a git repository: /src/firedancer/../.git/modules/firedancer`.

Cloning the fork URL inside the container gives a real git repo, makes
submodule init work, and pins the target by URL + immutable commit per
AGENTS.md's provenance rule. The clone+submodule path was validated in a
throwaway container (HEAD = `ff881b69`, agave = `535ec972`).

## Runtime contract (verified gate)

On this Mac Studio the validator **cannot start**. Frankendancer's
`fdctl run` and `fdctl configure init all` paths call
`fd_cfg_stage_hugetlbfs` / `fd_shmem_private_boot`, which require
`/sys/devices/system/node/*/hugepages/*` and a mountable `hugetlbfs`.
OrbStack's kernel exposes **neither** on arm64 nor amd64-via-Rosetta
containers/VMs (verified by live probe on 2026-09-28) — no
`/sys/devices/system/node`, no `/sys/kernel/mm/hugepages`, no
`/proc/sys/vm/nr_hugepages`, cannot mount hugetlbfs. This is identical to the
WSL2 `numa_cnt 0` blocker. **The gate is the OrbStack kernel, not the distro
or a config knob.**

### Honest evidence ceiling on this Mac

`built` — the image exists, `fdctl` + `solana` binaries report their
versions, and the source pin/deviation inventory is captured. Nothing more.

`started` / `joined` / `voting` require a **dedicated bare-metal x86_64 Linux
host** with real NUMA sysfs, hugepages, ~256 GiB RAM, and root. There the
compose/Kurtosis `run` path (real_run=True with a config + keys artifact) is
the intended invocation.

## Artifacts

| File | Purpose |
| --- | --- |
| `Dockerfile.firedancer` | build + runtime image; records all deviations in `BUILD-INFO` labels |
| `build-firedancer.sh` | source-pin verification, disk/memory guards, buildx cross-build |
| `firedancer-entrypoint.sh` | `run` / `configure` / `version` / passthrough; never fakes NUMA |
| `compose.firedancer.yaml` | compose profile; default `command: version` (build-evidence) |
| `smoke-firedancer.sh` | records `built` evidence and confirms the runtime gate fails |
| `kurtosis/firedancer-single-node.star` | Kurtosis launcher (`prepared`; `version` default) |
| `verification-firedancer-frankendancer.json` | `built` evidence (written by `smoke-firedancer.sh`) |

## Usage

Build-evidence (the honest default on this host):

```bash
docker --context orbstack run --rm --platform linux/amd64 \
       solana-diff/firedancer:v26.09.4-frankendancer-amd64 version
```

Real run (only on a NUMA+hugepages host, with a config.toml + keypair volume):

```bash
docker --context orbstack run --rm --platform linux/amd64 \
       --privileged -v firedancer-data:/var/lib/firedancer \
       solana-diff/firedancer:v26.09.4-frankendancer-amd64 run
```
