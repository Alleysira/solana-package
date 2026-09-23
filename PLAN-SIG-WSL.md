# SIG v2 on Ubuntu 20.04 WSL2

This is an execution runbook for the current Syndica SIG implementation in
Zig.  It is not evidence that SIG has already been built or run.  Execute it
after `PLAN-FIREDANCER-WSL.md` so the Firedancer compatibility library can be
included in the final comparison when available.

SIG v2 is not yet a self-sufficient voting validator.  It requires an
externally generated leader schedule and a complete shred stream beginning at
its snapshot slot because repair is not implemented.  This runbook therefore
targets:

1. a pinned SIG v2 build;
2. its public conformance library and fixture suite;
3. a live component comparison with pinned Agave, and with Firedancer when
   its library was built by the preceding runbook; and
4. a conditional **observer** process test when all external runtime inputs
   are actually available.

Never describe the result as a SIG voting validator or as five voting
validators.

## Fixed inputs

| Input | Immutable value |
| --- | --- |
| SIG repository | `https://github.com/Syndica/sig.git` |
| SIG v2 commit | `b5026c60fe56b51edd79131115b7e741449d6b2e` |
| Zig version | `0.15.2` |
| Zig Linux x86_64 archive | `zig-x86_64-linux-0.15.2.tar.xz` |
| Zig archive SHA-256 | `02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239` |
| Test-vectors repository | `https://github.com/firedancer-io/test-vectors.git` |
| SIG test-vectors commit | `80a9451e4d54337eb66d228dde887c9e0e8b63fb` |
| solfuzz-agave repository | `https://github.com/firedancer-io/solfuzz-agave.git` |
| solfuzz-agave commit | `3fe328dfa247e2b0275fad91bc90a23b38dac543` |
| solfuzz-agave Agave revision | `01fab2a3e3954b74c2026ef71b3658619248cdc1` |
| solfuzz-agave protosol | v10.0.0, `e3f561fbfcfd8f3f8983aff813aa27a53d4b1eaf` |
| Rust toolchain | `1.95.0` |
| solana-conformance repository | `https://github.com/firedancer-io/solana-conformance.git` |
| solana-conformance commit | `0058c4b94b007ba25b13deeec46b6322fa6f051f` |

The pinned `solana-conformance` tree vendors an older protosol schema (v5.4),
while the SIG/solfuzz-agave target pair uses v10.0.0.  The shared-object ABI is
designed to remain stable, but schema and feature differences must be recorded
and validated.  A decode or comparison failure is not automatically an
implementation bug.

## Result and interruption policy

Use the evidence levels and terminology in the workspace `AGENTS.md`.  A
stage status is one of `PASS`, `FAIL`, `BLOCKED`, or `SKIPPED`; the highest
evidence level is recorded separately.

Before installing tools or cloning sources, create an immutable attempt:

```bash
test -f AGENTS.md
test -f survey.md
test -f solana-package/clients.lock.json
test -f solana-package/MULTICLIENT.md

WORKSPACE="$(pwd -P)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
ATTEMPT_DIR="$WORKSPACE/solana-package/evidence/sig-v2-wsl/$RUN_ID"
mkdir -p \
  "$ATTEMPT_DIR/logs" \
  "$ATTEMPT_DIR/raw" \
  "$ATTEMPT_DIR/manifests" \
  "$ATTEMPT_DIR/results"
```

Immediately create `$ATTEMPT_DIR/checkpoint.json` and
`$ATTEMPT_DIR/events.jsonl`.  After every numbered stage, atomically update
the checkpoint and append an event containing timestamp, status, command exit
codes, log paths, highest evidence level, and the next resumable stage.  Use
`apply_patch` for workspace files.  For generated evidence, validate a
same-directory temporary file before renaming it over the checkpoint.

Never keep the only copy of progress in chat.  Do not log tokens, credentials,
keypair contents, full environment dumps, or private snapshot URLs.  A failed
component command does not skip evidence finalization.  Independent stages
continue where safe: for example, a blocked observer does not invalidate a
completed differential run.

## Stage 1 — Host inventory and build gate

Record these outputs under `$ATTEMPT_DIR/raw/host/`:

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
```

The build gate passes only when:

1. the system is WSL2 Linux x86_64 with kernel at least 4.18;
2. the workspace is on the WSL ext4 VHD, not `/mnt/<drive>`, drvfs, 9p, CIFS,
   or fuseblk;
3. at least 32 GiB `MemTotal`, four online CPUs, and 100 GiB free disk are
   available.

If the gate fails, record `BLOCKED`, finalize the attempt, update the mandatory
workspace status documents, and stop.  Do not move compiler caches or account
databases to a Windows-mounted filesystem to bypass the gate.

Record the observed host resources rather than assuming the nominal WSL
configuration is active.

## Stage 2 — Base packages, Zig, and Rust

Install the non-versioned Ubuntu dependencies and retain the apt log:

```bash
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git xz-utils jq python3 python3-pip \
  build-essential pkgconf cmake clang libclang-dev llvm-dev \
  libudev-dev protobuf-compiler software-properties-common
```

Install Zig in an attempt-independent, versioned workspace tool directory;
do not replace a system `zig` symlink:

```bash
TOOLS_DIR="$WORKSPACE/.runs/tools"
ZIG_ARCHIVE="$TOOLS_DIR/zig-x86_64-linux-0.15.2.tar.xz"
ZIG_DIR="$TOOLS_DIR/zig-x86_64-linux-0.15.2"
mkdir -p "$TOOLS_DIR"
curl --fail --location --proto '=https' --tlsv1.2 \
  --output "$ZIG_ARCHIVE" \
  https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz
printf '%s  %s\n' \
  '02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239' \
  "$ZIG_ARCHIVE" | sha256sum --check --strict -
```

Do not extract unless checksum verification succeeds.  If `$ZIG_DIR` already
exists, verify its `zig version` and binary SHA-256; use an attempt-specific
extraction directory rather than overwriting an unverifiable install.

For a new versioned install:

```bash
test ! -e "$ZIG_DIR"
tar -xJf "$ZIG_ARCHIVE" -C "$TOOLS_DIR"
test -x "$ZIG_DIR/zig"
```

After extraction:

```bash
export PATH="$ZIG_DIR:$PATH"
zig version
file "$ZIG_DIR/zig"
sha256sum "$ZIG_DIR/zig"
```

`zig version` must be exactly `0.15.2`.

Install Rust through rustup only if `cargo +1.95.0` is not already available:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain none
source "$HOME/.cargo/env"
rustup toolchain install 1.95.0 --profile minimal
cargo +1.95.0 --version
rustc +1.95.0 --version
```

Record the rustup installer URL, resulting toolchain metadata, and cargo/rustc
versions.  Do not use an unpinned `stable` toolchain for the Agave target.

## Stage 3 — Isolated SIG checkout and v2 build

Source selection is deterministic:

1. Use `$WORKSPACE/sig` only if its origin is the fixed repository, `HEAD` is
   the fixed commit, and it has no tracked modifications.
2. Otherwise preserve it and clone into
   `$WORKSPACE/.runs/sources/sig-b5026c60-$RUN_ID`.
3. Never reset, clean, or switch an existing user checkout.

For an isolated checkout:

```bash
git clone --filter=blob:none https://github.com/Syndica/sig.git "$SIG_SOURCE"
git -C "$SIG_SOURCE" fetch origin b5026c60fe56b51edd79131115b7e741449d6b2e
git -C "$SIG_SOURCE" checkout --detach b5026c60fe56b51edd79131115b7e741449d6b2e
git -C "$SIG_SOURCE" submodule update --init --recursive
```

Record `rev-parse HEAD`, remote URLs, recursive submodule status, and tracked
worktree status.  Continue only when the commit is exact and the tracked tree
is clean.

Pre-fetch the dependencies pinned by Zig manifests, then build using the same
feature fallbacks as upstream Linux CI:

```bash
cd "$SIG_SOURCE"
./tools/fetch-zig-deps.py

zig build sig \
  -Dallow-no-sha -Dallow-no-avx512 \
  --summary all

zig build ci \
  -Dallow-no-sha -Dallow-no-avx512 \
  --summary all
```

The `allow-no` options permit CPUs without SHA extensions or AVX-512; record
the actual CPU flags and selected fallback.  They do not permit silently
skipping failed tests.

Verify and record:

```bash
test -x zig-out/bin/sig
file zig-out/bin/sig
sha256sum zig-out/bin/sig
ldd zig-out/bin/sig
```

Save full build/test output and exit codes.  A successful executable plus the
successful `ci` target establishes the SIG executable at `built`, subject to
the separate conformance-library build below.

## Stage 4 — SIG conformance library and pinned fixtures

Build the dedicated conformance project:

```bash
cd "$SIG_SOURCE"
./tools/fetch-zig-deps.py conformance/build.zig.zon
cd conformance

zig build \
  -Dallow-no-sha -Dallow-no-avx512 \
  -Ddisable-feature-status-logs \
  --summary all
```

Verify these outputs:

```text
$SIG_SOURCE/conformance/zig-out/bin/run
$SIG_SOURCE/conformance/zig-out/lib/libsolfuzz_sig.so
```

Record `file`, `ldd`, SHA-256, and
`nm -D --defined-only` for `libsolfuzz_sig.so`.

Populate `conformance/env/test-vectors` at the fixed commit.  Preserve an
existing wrong or dirty checkout and use a fresh attempt-specific source,
then link it into the expected `env/test-vectors` location only inside this
isolated SIG checkout:

```bash
git clone --filter=blob:none \
  https://github.com/firedancer-io/test-vectors.git "$SIG_VECTORS"
git -C "$SIG_VECTORS" fetch origin 80a9451e4d54337eb66d228dde887c9e0e8b63fb
git -C "$SIG_VECTORS" checkout --detach 80a9451e4d54337eb66d228dde887c9e0e8b63fb
mkdir -p "$SIG_SOURCE/conformance/env"
test ! -e "$SIG_SOURCE/conformance/env/test-vectors"
ln -s "$SIG_VECTORS" "$SIG_SOURCE/conformance/env/test-vectors"
```

Before running tests, create a sorted manifest of every `.fix` relative path,
size, and SHA-256.  Save copies and SHA-256 values for:

```text
conformance/scripts/unimplemented_harnesses.txt
conformance/scripts/misc_failures.txt
conformance/commits.env
```

Confirm that `commits.env` resolves to the fixed test-vectors,
solfuzz-agave, and protosol pins listed at the top of this runbook.

Run SIG's CI selection:

```bash
cd "$SIG_SOURCE/conformance"
timeout --signal=INT --kill-after=30s 90m scripts/ci-run.sh
```

The script intentionally recreates only
`conformance/env/split-fixtures` inside the isolated checkout.  Do not point
that path at user data.  After it runs, create an executed-fixture manifest by
resolving every symlink in `env/split-fixtures` back to its source path and
recording its SHA-256.

The expected CI selection excludes:

- unimplemented top-level harnesses `block`, `cost`, and `gossip`; and
- exact fixtures listed in `misc_failures.txt`.

Report the total input, excluded-by-harness, excluded-known-failure, selected,
passed, and failed counts separately.  A zero-failure CI result does not mean
the excluded surfaces are supported.

## Stage 5 — Build the exact Agave conformance reference

Clone the fixed solfuzz-agave source into an isolated path:

```bash
git clone https://github.com/firedancer-io/solfuzz-agave.git "$SOLFUZZ_AGAVE_SOURCE"
git -C "$SOLFUZZ_AGAVE_SOURCE" fetch origin 3fe328dfa247e2b0275fad91bc90a23b38dac543
git -C "$SOLFUZZ_AGAVE_SOURCE" checkout --detach 3fe328dfa247e2b0275fad91bc90a23b38dac543
git -C "$SOLFUZZ_AGAVE_SOURCE" submodule update --init --recursive
```

Before building, verify from its lockfiles/submodules that the Agave revision
is `01fab2a3e3954b74c2026ef71b3658619248cdc1` and protosol is v10.0.0 at
`e3f561fbfcfd8f3f8983aff813aa27a53d4b1eaf`.  A pin mismatch is `BLOCKED`;
do not substitute another Agave revision.

Build the shared library:

```bash
cd "$SOLFUZZ_AGAVE_SOURCE"
cargo +1.95.0 build --lib --release --locked
```

The required artifact is:

```text
$SOLFUZZ_AGAVE_SOURCE/target/release/libsolfuzz_agave.so
```

Record its SHA-256, `file`, `ldd`, and exported `sol_compat_*` symbols.
Run SIG's feature compatibility check:

```bash
cd "$SIG_SOURCE/conformance"
python3 scripts/check_feature_compat.py \
  zig-out/lib/libsolfuzz_sig.so \
  "$SOLFUZZ_AGAVE_SOURCE/target/release/libsolfuzz_agave.so"
```

Save machine-readable output when the script provides it and the full text log
in all cases.  A feature difference must be resolved or explicitly classified
before interpreting semantic mismatches.

## Stage 6 — Install the pinned comparison runner

Ubuntu 20.04's default Python is too old for the pinned runner.  Install
Python 3.11 in parallel with the system Python.  If the packages are not in
the configured apt sources, add only `ppa:deadsnakes/ppa`:

```bash
if ! apt-cache show python3.11 >/dev/null 2>&1; then
  sudo add-apt-repository -y ppa:deadsnakes/ppa
  sudo apt-get update
fi
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3.11 python3.11-dev python3.11-venv
```

Clone the runner with pinned submodules.  Preserve any existing dirty checkout:

```bash
git clone --recurse-submodules \
  https://github.com/firedancer-io/solana-conformance.git \
  "$SOLANA_CONFORMANCE_SOURCE"
git -C "$SOLANA_CONFORMANCE_SOURCE" fetch origin \
  0058c4b94b007ba25b13deeec46b6322fa6f051f
git -C "$SOLANA_CONFORMANCE_SOURCE" checkout --detach \
  0058c4b94b007ba25b13deeec46b6322fa6f051f
git -C "$SOLANA_CONFORMANCE_SOURCE" submodule update --init --recursive
```

Record the recursive submodule state, especially the vendored protosol
revision.  Install into a checkout-local virtual environment without changing
the default `python3`, `gcc`, or `g++` alternatives:

```bash
cd "$SOLANA_CONFORMANCE_SOURCE"
./deps.sh
python3.11 -m venv test_suite_env
source test_suite_env/bin/activate
python -m pip install --upgrade pip
python -m pip install -e '.[dev]'

solana-conformance --version
solana-conformance check-deps
solana-conformance list-harness-types
```

Do not run code generation when the pinned generated bindings are already
present; it could dirty the source or silently move schema versions.  If
`check-deps` says generation is required, record `BLOCKED` and inspect the
pinned checkout rather than regenerating from an unpinned remote source.

## Stage 7 — Construct the common fixture set

The first differential batch is deliberately restricted to the common public
surface:

| Fixture category | Required exported symbol |
| --- | --- |
| `instr` | `sol_compat_instr_execute_v1` |
| `txn` | `sol_compat_txn_execute_v1` |
| `elf_loader` | `sol_compat_elf_loader_v1` |
| `syscall` | `sol_compat_vm_syscall_execute_v1` |

For each category, require the symbol in both
`libsolfuzz_agave.so` and `libsolfuzz_sig.so`.  When the Firedancer target is
present, require it there as well for the three-target batch.  A missing
symbol removes only that category and is recorded as `unsupported`; it is not
a mismatch.

Create `$ATTEMPT_DIR/common-fixtures/` as a category-preserving symlink tree
to the fixed test-vectors checkout.  Selection is deterministic:

1. include only `.fix` files under the four categories above;
2. remove exact paths listed in SIG's `misc_failures.txt` for the clean
   baseline batch;
3. never include `block`, `cost`, or `gossip`;
4. record any fixture rejected by `solana-conformance validate-fixtures` as a
   schema/runner compatibility gap rather than silently dropping it.

Create `common-fixtures.json` containing each selected relative path,
category, size, and SHA-256, plus every exclusion and its reason.  Save the
manifest SHA-256 and selected counts.

Validate the complete set before execution:

```bash
solana-conformance validate-fixtures \
  -i "$ATTEMPT_DIR/common-fixtures"
```

If no fixture survives capability and schema validation, mark differential
execution `BLOCKED`; do not claim `differential`.

## Stage 8 — Agave/SIG baseline and optional Firedancer comparison

Define the targets:

```text
AGAVE_SO=<solfuzz-agave>/target/release/libsolfuzz_agave.so
SIG_SO=<sig>/conformance/zig-out/lib/libsolfuzz_sig.so
FD_SO=<Firedancer OBJDIR>/lib/libfd_exec_sol_compat.so
```

Obtain `FD_SO` from the attempt recorded by `PLAN-FIREDANCER-WSL.md`.  Verify
its commit, artifact SHA-256, and component result before using it.  Full
Firedancer validator startup is not required for component comparison.  If no
valid Firedancer library exists, run Agave/SIG and mark only the three-target
portion `SKIPPED`; do not skip the two-target baseline.

First run SIG's native dynamically loaded runner independently against the
Agave and SIG libraries, retaining exact stdout/stderr and exit codes:

```bash
cd "$SIG_SOURCE/conformance"
zig build run -Dno-sig -- \
  "$ATTEMPT_DIR/common-fixtures" "$AGAVE_SO"
zig build run -Dno-sig -- \
  "$ATTEMPT_DIR/common-fixtures" "$SIG_SO"
```

If `FD_SO` is valid, run it through the same fixture selection as an
additional ABI/expected-effect check.

Then use the pinned comparison runner.  Shared-object basenames must remain
unique.  For Agave/SIG:

```bash
solana-conformance run-tests \
  -i "$ATTEMPT_DIR/common-fixtures" \
  -s "$AGAVE_SO" \
  -t "$SIG_SO" \
  -o "$ATTEMPT_DIR/results/agave-sig-strict" \
  -p 2 -sf -ss
```

For the three-target batch, when available:

```bash
solana-conformance run-tests \
  -i "$ATTEMPT_DIR/common-fixtures" \
  -s "$AGAVE_SO" \
  -t "$SIG_SO" \
  -t "$FD_SO" \
  -o "$ATTEMPT_DIR/results/agave-sig-firedancer-strict" \
  -p 2 -sf -ss
```

Repeat each executed batch with `--consensus-mode` into a distinct
`*-consensus` directory.  The strict result preserves all effect differences;
consensus mode provides the runner's normalized comparison.  Preserve both.

`run-tests` may exit nonzero because it found semantic differences.  Capture
the exit code, continue to mismatch triage, and do not mislabel that as a
build failure.

`differential` is established only when the same normalized input was
executed by at least two genuinely distinct live libraries and their effects
were actually compared.  Embedded expected results alone are not sufficient
when a live Agave target could not be built.

## Stage 9 — Extended surfaces and mismatch triage

After the four-category common batch, construct separate extended batches for
shred parsing, VM execution/validation, and serialization only when all
selected targets export the required functions and the pinned runner can
decode the fixtures.  Never mix an extended unsupported failure into the
common-batch pass rate.

For every strict or normalized mismatch:

1. Save its relative path, SHA-256, category, and all target results.
2. Re-run the one fixture at least twice with one process, verbose/debug mode,
   and a separate output directory.  A representative invocation is:

   ```bash
   solana-conformance run-tests \
     -i <one-fixture> \
     -s "$AGAVE_SO" \
     -t "$SIG_SO" \
     -o <rerun-directory> \
     -p 1 -d -v -sf -ss
   ```

3. Check whether the mismatch reproduces byte-for-byte and whether it remains
   after `--consensus-mode` normalization.
4. Classify it as exactly one of:
   - `harness`
   - `version/configuration`
   - `unsupported`
   - `implementation`
   - `unresolved`
5. Use `implementation` only after source/protocol evidence rules out harness,
   schema, feature, loader, account, sysvar, commitment, and unsupported-path
   causes.  When that proof is absent, use `unresolved`.
6. Minimize the fixture where practical without changing its semantic
   preconditions, and retain a deterministic reproducer.

Do not treat Agave/Firedancer agreement as the specification or use majority
voting.  Consult source behavior, applicable protocol/SIMD requirements, and
paired or metamorphic tests when deciding which result is correct.

## Stage 10 — Conditional SIG observer run

This stage is independent of component differential success.  It is runnable
only when all of these concrete inputs exist:

```text
SIG_CLUSTER                 # cluster identifier matching every artifact
SIG_SNAPSHOT_DIR            # usable snapshot and known snapshot slot S
SIG_SNAPSHOT_SLOT           # numeric S
SIG_LEADER_SCHEDULE_FILE    # schedule covering replayed slots
SIG_LEDGER_DIR              # complete ledger/shred source beginning at S
```

The ledger must contain every required slot from the snapshot boundary.  A
normal gossip endpoint is insufficient because SIG v2 has no repair.  If any
input is absent, inconsistent, unverifiable, or has a gap, mark this stage
`BLOCKED` with the exact missing prerequisite.  Do not download an arbitrary
public snapshot or mix clusters to make the process start.

When an Agave CLI/RPC source is intentionally provided, generate the schedule
with `solana leader-schedule` and retain its command, cluster URL with secrets
redacted, slot range, SHA-256, and exit code.  Do not assume an old schedule is
valid for a new snapshot.

Render an attempt-specific copy of `config/example.zon` with:

```zig
.{
    .sandboxing_mode = .sandboxed,
    .cluster = .<MATCHING_CLUSTER>,
    .leader_schedule_file = "<ABSOLUTE_SCHEDULE_PATH>",
    .gossip = .{
        .port = 8001,
        .advertise_tvu_port = true,
    },
    .shred_network = .{
        .recv_port = 8002,
    },
    .telemetry = .{
        .port = 9110,
        .log_level = .info,
    },
    .snapshot = .{
        .folder = "<ABSOLUTE_SNAPSHOT_DIRECTORY>",
        .known_validators = .{"*"},
    },
    .accounts_db = .{
        .file = "<ATTEMPT_RUNTIME_DIRECTORY>/accounts.db",
        .rooted = .{ .gb = 8 },
        .unrooted = .{ .gb = 8 },
    },
}
```

Keep the runtime directory on WSL ext4 and confirm at least 32 GiB
`MemAvailable` and 100 GiB free disk before starting.  Ensure ports 8001,
8002, and 9110 are unused.  The preceding Firedancer attempt must be stopped
before reusing them.

Run SIG without systemd through a bounded wrapper and save all service logs:

```bash
cd "$SIG_SOURCE"
timeout --signal=INT --kill-after=30s 20m \
  zig build run -- "$SIG_RUNTIME_CONFIG" \
  >"$ATTEMPT_DIR/logs/sig-observer.log" 2>&1 &
SIG_WRAPPER_PID=$!
```

Once all expected services are healthy and telemetry responds, stream the
complete ledger:

```bash
timeout --signal=INT --kill-after=30s 15m \
  zig build shred-stream -- \
  --ledger "$SIG_LEDGER_DIR" \
  --target 127.0.0.1:8002 \
  --rate-hz 100
```

Collect `http://127.0.0.1:9110` telemetry and process/service status at least
four times, 30 seconds apart.  Record snapshot slot, first received shred,
highest contiguous received slot, highest replayed slot, account database
state, process exits, and any gaps.

Acceptance is strict:

- `started`: the pinned SIG executable launches all expected services, remains
  alive for at least five minutes, and exposes telemetry.
- Observer replay evidence additionally requires a contiguous shred stream
  from the snapshot slot and advancing replay state.
- `joined` may be recorded only if another authentic node's machine-readable
  gossip/network view observes this SIG identity.
- Never record `voting`; do not require or invent a vote account.

If `.sandboxed` fails specifically because WSL does not support a required
namespace or seccomp operation, preserve the failure and allow one retry with
`.sandboxing_mode = .threaded`.  Record the reduced isolation prominently.
Do not use threaded mode as a generic retry for unrelated crashes.

Stop both wrappers with `SIGINT`, wait for the grace period, verify all SIG
child processes exited, and retain the snapshot, ledger, accounts database,
rendered config, and logs.  Do not delete external source data by default.

## Stage 11 — Evidence contract and mandatory workspace updates

Create `$ATTEMPT_DIR/summary.json` with at least:

```text
schemaVersion, runId, startedAt, completedAt
host.{os,architecture,kernel,wslVersion,cpuModel,cpuCount,cpuFlags,
      memTotalBytes,swapBytes,filesystem,diskFreeBytes}
sig.{repository,commit,zigVersion,buildOptions,binarySha256}
conformance.{librarySha256,runnerSha256,testVectorsCommit,
             allFixtureManifest,selectedFixtureManifest,
             exclusions,ciCounts,ciStatus}
agaveTarget.{repository,commit,agaveRevision,protosolRevision,
             rustVersion,librarySha256,featureCompatibility}
firedancerTarget.{used,commit,librarySha256,sourceAttempt}
comparison.{strictRuns,normalizedRuns,perTargetCounts,mismatches,
            classifications,reproducers}
observer.{prerequisites,status,configSha256,snapshotSlot,
          scheduleSha256,serviceSamples,telemetrySamples,replayRange,
          sandboxingMode}
phases[]                       # PASS/FAIL/BLOCKED/SKIPPED and exit codes
highestEvidenceLevel
limitations[]
cleanup.{completed,remainingProcesses,remainingState[]}
```

All paths must be workspace-relative.  Validate the JSON with `jq empty`.
Create a sorted SHA-256 manifest for raw logs, configs, fixture manifests, and
results, excluding the manifest itself, credentials, and private key material.

Maintain `solana-package/verification-sig-v2-wsl.json` as an append-only
index:

```text
schemaVersion
target repository/commit/Zig version
attempts[]: runId, completedAt, status, highestEvidenceLevel,
            summaryPath, summarySha256, limitations
```

Never erase failed or superseded attempts.  Append atomically and retain all
prior entries.

Before ending the task, even after `FAIL` or `BLOCKED`:

1. Update `AGENTS.md` `Last reviewed` using Asia/Shanghai date.
2. Update the SIG row with the highest proven level and remaining gap.
3. Update the Firedancer row too if this run produced new Firedancer component
   differential evidence.
4. Update `Current overall result` and `Next milestones` when the critical
   path changed.
5. Append a complete Experiment log entry for the build/differential/observer
   attempt.
6. Update `solana-package/clients.lock.json` when the current SIG v2 pin or a
   build/conformance capability conclusion changes.  Keep the old stable
   v0.1.0 RPC-library provenance distinct from the v2 research target.
7. Update `solana-package/MULTICLIENT.md` when the runtime or observer
   deployment conclusion changes.

A successful conformance campaign can establish `differential` even when the
observer stage is blocked.  Conversely, process liveness without component or
replay evidence does not establish differential, joined, or voting behavior.
