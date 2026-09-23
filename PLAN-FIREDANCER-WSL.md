# Firedancer v26.09.4 on Ubuntu 20.04 WSL2

This is an execution runbook, not evidence that Firedancer has already been
built or run.  Execute it from the root of the `solana-diff-testing`
workspace on the target machine.  Do not change versions or relax a gate to
make the run pass.

The target is **full Firedancer**, not Frankendancer.  The expected host is
Ubuntu 20.04 under WSL2 with 64 GiB configured RAM and a 1 TB SSD.  This host
is below the approximately 109 GiB footprint reported for the release's
normal testnet configuration, so the full-validator phase is conditional on
the measured low-memory topology described below.  A blocked validator phase
does not invalidate successful build or component evidence.

## Fixed inputs

| Input | Immutable value |
| --- | --- |
| Firedancer repository | `https://github.com/firedancer-io/firedancer.git` |
| Release | `v26.09.4` |
| Firedancer commit | `d70ace98ec2ddf407bfc816cc4f327ddcf6897bb` |
| Test-vectors repository | `https://github.com/firedancer-io/test-vectors.git` |
| Firedancer-native test-vectors commit | `0e8d5f061df4e79596141658d78ab9b0f2eb489e` |
| Build machine | `linux_gcc_x86_64` |
| C/C++ compiler | GCC/G++ 11 |
| Network provider | `socket` |

The `socket` backend is deliberate for WSL.  Passing this runbook does not
establish XDP support or XDP performance.

## Result and interruption policy

Use the exact evidence levels defined in the workspace `AGENTS.md`.  Every
stage has one of `PASS`, `FAIL`, `BLOCKED`, or `SKIPPED`.  Record only the
highest evidence level actually proven.

Before installing packages or cloning sources, create an immutable attempt
directory and start a checkpoint:

```bash
test -f AGENTS.md
test -f survey.md
test -f solana-package/clients.lock.json
test -f solana-package/MULTICLIENT.md

WORKSPACE="$(pwd -P)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
ATTEMPT_DIR="$WORKSPACE/solana-package/evidence/firedancer-26094-wsl/$RUN_ID"
mkdir -p "$ATTEMPT_DIR/logs" "$ATTEMPT_DIR/raw" "$ATTEMPT_DIR/manifests"
```

Immediately create `$ATTEMPT_DIR/checkpoint.json` and
`$ATTEMPT_DIR/events.jsonl`.  After every numbered stage, atomically update
the checkpoint and append an event containing:

- UTC timestamp and stage name;
- status and command exit codes;
- paths to newly created logs;
- the current highest evidence level; and
- the next stage that is safe to resume.

Use `apply_patch` for workspace files.  For generated evidence, write a
temporary file in the same directory, validate it, then rename it over the
checkpoint.  Never leave the only progress record in chat output.  Do not put
keypair contents, credentials, environment dumps, or access tokens in logs.

If a command fails, capture its exit code and log before deciding whether its
dependent stages are `BLOCKED`.  Always run the evidence finalization and
cleanup stages.

## Stage 1 — Host inventory and hard build gate

Save the complete output of these read-only probes under
`$ATTEMPT_DIR/raw/host/`:

```bash
uname -a
uname -m
cat /etc/os-release
cat /proc/version
lscpu
nproc
free -b
cat /proc/meminfo
swapon --show --bytes
df -B1 -T "$WORKSPACE"
findmnt -T "$WORKSPACE" -o SOURCE,FSTYPE,TARGET,OPTIONS
ulimit -a
ip -brief address
ip route
mount
cat /proc/cgroups
```

Also record whether `/proc/version` or `uname -r` contains `microsoft`, the
default WSL interface, the WSL kernel version, CPU flags, and available
AVX/AVX2/AVX-512 support.

The build gate passes only when all of these are true:

1. `uname -s` is `Linux` and `uname -m` is `x86_64`.
2. This is WSL2, not WSL1, and the parsed kernel version is at least 4.18.
3. The workspace is not below `/mnt/<drive>` and its filesystem is not
   `drvfs`, `9p`, `cifs`, or `fuseblk`.  Source, build output, ledger, and
   accounts data must remain on the WSL ext4 VHD.
4. `/proc/meminfo` reports at least 32 GiB `MemTotal`.
5. At least 8 logical CPUs are online.
6. At least 100 GiB is free on the workspace filesystem.

If any condition fails, mark the build stage `BLOCKED`, finalize the evidence,
update the workspace progress documents as described at the end, and stop.
Do not move the build to `/mnt/c` to obtain more disk space.

Record WSL configuration as an external prerequisite when visible.  Do not
edit the Windows user's `.wslconfig` automatically.  If WSL exposes less than
the configured resources, record the observed values rather than the nominal
64 GiB/1 TB values.

## Stage 2 — Packages and isolated pinned source

Install the normal build tools on Ubuntu 20.04 and save the apt transaction
log:

```bash
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git jq make build-essential pkgconf cmake clang \
  libclang-dev libudev-dev protobuf-compiler iproute2 ethtool python3 \
  software-properties-common
```

If `apt-cache show gcc-11` does not find a package, add only
`ppa:ubuntu-toolchain-r/test`, refresh apt, then install:

```bash
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y gcc-11 g++-11
```

Record `gcc-11 --version`, `g++-11 --version`, `clang --version`,
`cmake --version`, `protoc --version`, and the installed package versions.

Source selection is deterministic:

1. Use `$WORKSPACE/firedancer` only if its origin URL is the repository above,
   `HEAD` is the fixed commit, and it has no tracked modifications.
2. Otherwise, preserve it and clone into
   `$WORKSPACE/.runs/sources/firedancer-d70ace98-$RUN_ID`.
3. Never use `git reset`, `git checkout --`, or clean an existing user tree.

For a new isolated checkout:

```bash
git clone --filter=blob:none https://github.com/firedancer-io/firedancer.git "$FD_SOURCE"
git -C "$FD_SOURCE" fetch origin d70ace98ec2ddf407bfc816cc4f327ddcf6897bb
git -C "$FD_SOURCE" checkout --detach d70ace98ec2ddf407bfc816cc4f327ddcf6897bb
```

Initialize all pinned submodules and record their immutable state:

```bash
git -C "$FD_SOURCE" submodule update --init --recursive
git -C "$FD_SOURCE" rev-parse HEAD
git -C "$FD_SOURCE" submodule status --recursive
git -C "$FD_SOURCE" status --porcelain --untracked-files=no
```

The commit must match exactly, all submodules must be initialized without a
leading `-` or `+`, and the tracked tree must be clean.  Otherwise mark the
build `BLOCKED`.

Run the workspace preflight after package installation:

```bash
FIREDANCER_MIN_RAM_GIB=32 \
FIREDANCER_MIN_DISK_GIB=100 \
FIREDANCER_MIN_CPUS=8 \
  "$WORKSPACE/solana-package/preflight-firedancer.sh" build "$FD_SOURCE"
```

Save its complete output and exit code.  Do not continue on a preflight
failure.

## Stage 3 — Reproducible build

Build from the source root.  Cap parallelism at four jobs to reduce WSL memory
pressure:

```bash
cd "$FD_SOURCE"
FD_AUTO_INSTALL_PACKAGES=1 CC=gcc-11 CXX=g++-11 \
  ./deps.sh fetch check install

source activate MACHINE=linux_gcc_x86_64 CC=gcc-11
MAKE_JOBS="$(nproc)"
if (( MAKE_JOBS > 4 )); then MAKE_JOBS=4; fi

make -j"$MAKE_JOBS" \
  firedancer firedancer-dev \
  libfd_exec_sol_compat.so \
  test_sol_compat test_sol_compat_so
```

Record the value printed for `OBJDIR`.  The required artifacts are:

```text
$OBJDIR/bin/firedancer
$OBJDIR/bin/firedancer-dev
$OBJDIR/lib/libfd_exec_sol_compat.so
$OBJDIR/unit-test/test_sol_compat
$OBJDIR/unit-test/test_sol_compat_so
```

For each artifact, record `realpath`, `stat`, `file`, SHA-256, and `ldd` where
applicable.  Record:

```bash
"$OBJDIR/bin/firedancer" version
"$OBJDIR/bin/firedancer-dev" version
nm -D --defined-only "$OBJDIR/lib/libfd_exec_sol_compat.so"
```

Do not use `./build/firedancer version`; the build is valid only when the
artifact under the captured `$OBJDIR` is verified.  A successful artifact set
establishes at most `built` after the component smoke checks below succeed.

## Stage 4 — Firedancer-native component validation

Use the pinned Firedancer test-vector set.  If an existing checkout is dirty or
wrong, preserve it and use an attempt-specific clone:

```bash
git clone --filter=blob:none https://github.com/firedancer-io/test-vectors.git "$FD_VECTORS"
git -C "$FD_VECTORS" fetch origin 0e8d5f061df4e79596141658d78ab9b0f2eb489e
git -C "$FD_VECTORS" checkout --detach 0e8d5f061df4e79596141658d78ab9b0f2eb489e
```

Create a sorted manifest containing every `.fix` relative path, byte size, and
SHA-256.  Record the total and per-top-level-harness fixture counts.

Run the built-in fixture runner with failure continuation and capture the
complete output:

```bash
timeout --signal=INT --kill-after=30s 90m \
  "$OBJDIR/unit-test/test_sol_compat" \
  --fail-fast 0 "$FD_VECTORS"
```

Then verify that the public shared library can be loaded, initialized, resolve
an instruction entrypoint, and finalized:

```bash
"$OBJDIR/unit-test/test_sol_compat_so" \
  --target "$OBJDIR/lib/libfd_exec_sol_compat.so" \
  --type instr
```

Save the exported `sol_compat_*` symbol list as a capability manifest.  A
crash, `dlopen`/`dlsym` failure, corrupt output, or an unclassified fixture
failure blocks the full-validator phase.  A deterministic mismatch may be
classified as version/configuration or unsupported only with fixture and log
evidence; do not call it an implementation defect merely because the expected
output differs.

When the binaries, compatibility library, load smoke, and component run have
all completed without an unclassified fatal failure, record `built` even if a
later host/runtime gate is blocked.

## Stage 5 — Render an isolated low-memory local configuration

Create a dedicated runtime user if it does not already exist:

```bash
if ! id firedancer >/dev/null 2>&1; then
  sudo useradd --system --home-dir /var/lib/firedancer \
    --create-home --shell /usr/sbin/nologin firedancer
fi
```

Use these attempt-specific locations:

```text
Runtime base: /var/lib/firedancer/wsl-<RUN_ID>
Config:       /var/lib/firedancer/wsl-<RUN_ID>/config.toml
Huge pages:   /var/lib/firedancer/wsl-<RUN_ID>/hugetlbfs
Identity:     /var/lib/firedancer/wsl-<RUN_ID>/identity.json
Vote account: /var/lib/firedancer/wsl-<RUN_ID>/vote-account.json
Genesis:      /var/lib/firedancer/wsl-<RUN_ID>/genesis.bin
```

Create the base directory as root, assign it to the `firedancer` user, and keep
key files mode `0600`.  Determine the interface from the default IPv4 route;
it must exist and must not be `lo`.

Render the following TOML using the concrete run ID and interface.  Use
`apply_patch` rather than a shell heredoc when the config is inside the
workspace; for `/var/lib` render a temporary file, validate it, then install it
with mode `0640` and owner `root:firedancer`.

```toml
name = "fd-wsl-<RUN_ID>"
user = "firedancer"
telemetry = false

[paths]
base = "/var/lib/firedancer/wsl-<RUN_ID>"
identity_key = "/var/lib/firedancer/wsl-<RUN_ID>/identity.json"
vote_account = "/var/lib/firedancer/wsl-<RUN_ID>/vote-account.json"
genesis = "/var/lib/firedancer/wsl-<RUN_ID>/genesis.bin"

[gossip]
entrypoints = []
port = 8001
host = ""

[snapshots]
genesis_download = false

[consensus]
expected_genesis_hash = ""
expected_shred_version = 0
wait_for_vote_to_start_leader = false

[hugetlbfs]
mount_path = "/var/lib/firedancer/wsl-<RUN_ID>/hugetlbfs"
max_page_size = "huge"

[accounts]
max_accounts = 1048576

[runtime.limits]
max_live_slots = 512
max_fork_width = 16

[layout]
verify_tile_count = 1
execrp_tile_count = 1

[tiles.shred]
max_pending_shred_sets = 512

[tiles.gui]
enabled = false
max_http_connections = 16
max_websocket_connections = 16
send_buffer_size_mb = 128

[net]
provider = "socket"
interface = "<WSL_DEFAULT_INTERFACE>"

[development.gossip]
allow_private_address = true

[development.genesis]
validate_genesis_hash = false
```

This is the upstream `minimal.toml` profile plus an isolated base directory,
local genesis settings, and `socket` networking.  Do not silently add further
memory reductions.

Generate keys and a local bootstrap genesis with the development binary:

```bash
sudo "$OBJDIR/bin/firedancer-dev" configure init keys genesis \
  --config "$FD_CONFIG"
sudo "$OBJDIR/bin/firedancer-dev" configure check keys genesis \
  --config "$FD_CONFIG"
```

From the creation log, parse and record the exact `genesis_hash=...` and
`Shred version: ...`.  Verify the genesis file's SHA-256, then replace the
blank/zero consensus values in the config with those exact values.  Save a
redacted copy and SHA-256 of the final config; never copy key contents into the
attempt directory.

## Stage 6 — Measured full-runtime gate

Memory estimation is read-only and must happen before hugepage allocation:

```bash
"$OBJDIR/bin/firedancer" mem --config "$FD_CONFIG" --json \
  >"$ATTEMPT_DIR/raw/firedancer-mem.json"
"$OBJDIR/bin/firedancer" mem --config "$FD_CONFIG" --sort \
  >"$ATTEMPT_DIR/raw/firedancer-mem.txt"
jq empty "$ATTEMPT_DIR/raw/firedancer-mem.json"
```

Read these values from the JSON:

```text
.summary.total_memory_locked_bytes
.summary.tile_cnt
.summary.required_huge_pages
.summary.required_gigantic_pages
```

The full runtime gate passes only when all of these are true:

1. `total_memory_locked_bytes` is no more than 48 GiB
   (`51539607552` bytes).
2. Current `MemAvailable` is at least locked bytes plus 8 GiB
   (`8589934592` bytes).
3. `nproc` is at least `tile_cnt + 2`.
4. At least 60 GiB `MemTotal` and 200 GiB free disk remain.
5. The chosen interface exists and is not loopback.
6. `required_gigantic_pages` is zero because the WSL profile uses 2 MiB
   pages.

Run the host preflight with thresholds derived from the topology:

```bash
REQUIRED_CPUS="$((TILE_CNT + 2))"
sudo env \
  FIREDANCER_INTERFACE="$FD_INTERFACE" \
  FIREDANCER_MIN_RAM_GIB=60 \
  FIREDANCER_MIN_DISK_GIB=200 \
  FIREDANCER_MIN_CPUS="$REQUIRED_CPUS" \
  "$WORKSPACE/solana-package/preflight-firedancer.sh" run "$FD_SOURCE"
```

If any gate fails, mark the full-validator stage `BLOCKED`, retain `built`, and
skip directly to cleanup/evidence finalization.  Do not reduce account limits,
live slots, tile counts, or the 8 GiB operating-system reserve without a new
reviewed plan.

## Stage 7 — Host initialization and full-validator run

Before mutation, capture:

- `/proc/meminfo` hugepage fields;
- all existing hugetlbfs mounts;
- relevant `vm`, `net.core`, and `fs` sysctls;
- interface channels and offload settings from `ethtool`;
- cgroup, memlock, nofile, process-priority, and user-namespace limits.

Initialize only after reviewing the captured state:

```bash
sudo "$OBJDIR/bin/firedancer" configure init all --config "$FD_CONFIG"
sudo "$OBJDIR/bin/firedancer" configure check all --config "$FD_CONFIG"
```

If either command fails, do not start the validator.  Save diagnostics and run
`configure fini all` during cleanup.

Do not install a systemd unit.  Run the validator through a bounded wrapper so
that WSL shutdown or an interrupted agent does not leave an unbounded process:

```bash
sudo timeout --signal=INT --kill-after=30s 20m \
  "$OBJDIR/bin/firedancer" run --config "$FD_CONFIG" \
  >"$ATTEMPT_DIR/logs/firedancer-run.log" 2>&1 &
FD_WRAPPER_PID=$!
```

Poll every five seconds for at most three minutes.  Each iteration records
process liveness and runs:

```bash
sudo "$OBJDIR/bin/firedancer" ready --config "$FD_CONFIG"
```

On ready, collect the following at least four times, 30 seconds apart:

```bash
curl -fsS -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getGenesisHash"}' \
  http://127.0.0.1:8899

curl -fsS -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' \
  http://127.0.0.1:8899

curl -fsS http://127.0.0.1:7999/metrics
sudo "$OBJDIR/bin/firedancer" metrics --config "$FD_CONFIG"
```

Extract and retain at least:

- RPC genesis hash and slot;
- `tower_vote_slot`;
- `tower_root_slot`;
- `replay_root_slot`; and
- `diag_vote_status`.

Acceptance is deliberately separated:

- `started`: the intended full Firedancer binary remains alive for at least
  five minutes after ready, exposes RPC and metrics, and reports the expected
  genesis hash.
- `voting`: in addition, `diag_vote_status` equals `3`, and vote, root, replay
  root, and RPC slot values advance between samples.
- A local single-node run is not `joined` and not `end-to-end`.

Do not require `sendTransaction`, `simulateTransaction`, or `getVoteAccounts`;
they are unimplemented in this release.  After the voting checks, an optional
diagnostic may run:

```bash
sudo "$OBJDIR/bin/firedancer-dev" txn --config "$FD_CONFIG" --count 1
```

This proves only QUIC ingress unless a machine-readable accepted transaction
and account effect are also captured.  It must not raise the evidence level.

## Stage 8 — Cleanup and recoverability

Stop the bounded wrapper with `SIGINT`, wait for it to exit, and only use
`SIGKILL` after the documented 30-second grace period.  Record the final exit
code and whether the wrapper timed out normally.

Always run:

```bash
sudo "$OBJDIR/bin/firedancer" configure fini all --config "$FD_CONFIG"
```

Then recapture the same mount, hugepage, sysctl, interface, limit, and process
state collected before initialization.  Upstream `configure fini` releases
hugetlbfs and reserved pages but does not necessarily restore raised sysctls,
network channel counts, or all interface settings.  List every remaining
difference explicitly.  Do not delete source checkouts, ledger/accounts data,
configs, or evidence by default.

Verify there are no remaining Firedancer processes associated with this
attempt.  If cleanup fails, the final result must prominently record the
remaining PID, mount, page reservation, or host mutation.

## Stage 9 — Evidence contract and mandatory workspace updates

Create `$ATTEMPT_DIR/summary.json` with at least:

```text
schemaVersion, runId, startedAt, completedAt
host.{os,architecture,kernel,wslVersion,cpuModel,cpuCount,cpuFlags,
      memTotalBytes,swapBytes,filesystem,diskFreeBytes,interface}
target.{repository,tag,commit,submodules,compiler,objdir,versionOutput}
artifacts[]                    # relative path, file type, SHA-256
phases[]                       # name, PASS/FAIL/BLOCKED/SKIPPED, exit codes, logs
fixtures.{repository,commit,count,manifestPath,manifestSha256}
resources.{memEstimate,tileCount,hugePages,gateValues,gatePassed}
runtime.{configSha256,genesisHash,shredVersion,identityPublicKey,
         voteAccountPublicKey,readyAt,rpcSamples,metricSamples}
highestEvidenceLevel
limitations[]
cleanup.{completed,remainingState[]}
```

Paths in JSON are relative to the workspace.  Validate JSON with `jq empty`.
Create a sorted SHA-256 manifest for all raw logs and artifacts, excluding the
manifest itself and all private keys.

Maintain `solana-package/verification-firedancer-26094-wsl.json` as an
append-only index:

```text
schemaVersion
target repository/tag/commit
attempts[]: runId, completedAt, status, highestEvidenceLevel,
            summaryPath, summarySha256, limitations
```

Never remove an earlier failed or superseded attempt.  If the index already
exists, append atomically and retain all prior entries.

Before ending the task, even on `FAIL` or `BLOCKED`:

1. Update `AGENTS.md` `Last reviewed` using Asia/Shanghai date.
2. Update the Firedancer row with the highest proven level and remaining gap.
3. Update `Current overall result` and `Next milestones` if the critical path
   changed.
4. Append a complete Experiment log entry.
5. Update `solana-package/clients.lock.json` when the build/runtime result
   changes its pinned capability conclusion.
6. Update `solana-package/MULTICLIENT.md` when the deployment conclusion
   changes.

Do not record `started` from process liveness alone, `voting` without advancing
vote/root evidence, or `end-to-end` without a cross-node transaction.
