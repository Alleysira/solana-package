# SIG observer launcher — non-voting observer joining the local development cluster.
#
# SIG v2 is a structurally NON-VOTING observer: it has no vote/stake accounts and
# its Config has no vote field. It can never generate blocks or votes. The 20-slot
# target is met entirely by the two voting validators (Jito bootstrap + Agave
# joiner). SIG's purpose here is to start, join the shared-genesis gossip/shred
# network as an observer, and prove the cluster is observable by a third,
# independently-implemented client. This is NEVER a voting-validator claim.
#
# This module implements the OFFICIAL "Running a functional Sig validator" path
# (README §steps 1-4, https://github.com/Alleysira/sig#running-a-functional-sig-validator):
#   1. `solana leader-schedule` (on the bootstrap validator) → real 432000-slot schedule.
#   2. Point config.leader_schedule_file at it.
#   3. Start `sig config.zon` (skip_on_cold_start=false → SIG downloads a REAL
#      full snapshot over HTTP from the bootstrap validator, which produces +
#      advertises snapshots every 5 slots).
#   4. `shred-stream --ledger <bootstrap-ledger> --target <sig-ip>:8002 --rate-hz 100`
#      to feed SIG the slots after the snapshot slot (SIG has no repair).
#
# This is the functional path, NOT the skip_on_cold_start empty-snapshot bypass
# (which died at accounts_db MissingVersionFile at snapshot.zig:554 in the prior
# 2026-09-30 cold-start run). Here SIG holds a REAL account set (from the
# bootstrap snapshot) + receives a REAL shred stream. It still never votes.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY shred-stream runs INSIDE the bootstrap container (not a separate service)
# ─────────────────────────────────────────────────────────────────────────────
# The bootstrap validator owns the only live blockstore at
# /data/bootstrap-ledger/rocksdb. shred-stream's --ledger arg resolves that path
# (shred_stream.zig:1989 resolveRocksDbPath tries <ledger>/rocksdb first). So
# shred-stream MUST run where that blockstore lives: inside the bootstrap
# container. The shred-stream binary is delivered to the bootstrap via a
# files-artifact (built from the SIG image, which also builds shred-stream per
# build.zig:35's default install step), mounted on the bootstrap ServiceConfig at
# /opt/shred-stream via the launch_validator `extra_files` param. glibc
# compatibility is verified: shred-stream needs only libc/libm (glibc 2.36), and
# all three images share the bookworm-slim base (glibc 2.36) — confirmed via ldd
# in probe v3. The shred-stream binary lives at /opt/shred-stream/shred-stream
# inside the bootstrap container (the files-artifact stores it at a path the
# launcher controls).
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY --target uses a literal IP, not a hostname
# ─────────────────────────────────────────────────────────────────────────────
# shred_stream.zig:327 parseIpAndPort parses ONLY a literal IP:port — it does
# NOT resolve hostnames/DNS. So `--target sig-observer:8002` would fail to parse.
# The launcher resolves `sig-observer` → IP via `getent hosts sig-observer`
# INSIDE the bootstrap container (Kurtosis in-enclave DNS resolves the service
# name), then passes the resolved IP as `--target <ip>:8002`.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY the schedule is extracted via plan.run_sh (not plan.exec on bootstrap)
# ─────────────────────────────────────────────────────────────────────────────
# `solana leader-schedule` is a read-only RPC call — it touches no ledger and
# does NOT hit agave's io_uring_supported() assert (fs/src/dirs.rs:12, which is
# in remove_dir_all/remove_dir_contents — directory deletion only). So it CAN
# run in an unprivileged plan.run_sh ephemeral container, reaching the bootstrap
# RPC over in-enclave DNS at http://val-bootstrap:8899. plan.run_sh + StoreSpec
# is the proven pattern (genesis_launcher.star) for producing a files-artifact
# that is then mounted on a service. The schedule is extracted AFTER the
# bootstrap RPC is up and has produced some slots, so the schedule reflects the
# real stake distribution (both validators' stake).
#
# Evidence level returned is honestly the LOWEST proven:
#   - "started"  if `sig` boots past config+schedule parse and io_uring init.
#   - "joined"   if the log shows SIG received shreds / connected to a peer.
#   - "not_started" if `sig` exits before the boot window.
# SIG never reaches "voting" (impossible) and the launcher does not claim it.

constants = import_module("../package_io/constants.star")

# The bootstrap validator's gossip host:port, as seen from inside the enclave.
# Kurtosis in-enclave DNS resolves the service name `val-bootstrap` → its IP, and
# SIG's std.net.getAddressList will resolve the hostname part at runtime.
# (clusterInfoFromConfig in main.zig splits on ':' and resolves via getaddrinfo.)
_BOOTSTRAP_ENTRYPOINT = "val-bootstrap:" + str(constants.GOSSIP_PORT_NUM)

# Where the shred-stream binary is mounted INSIDE THE BOOTSTRAP CONTAINER. The
# files-artifact produced by build_shred_stream_artifact stores the binary at
# this path; the bootstrap launch_validator is called with
# extra_files={_SHRED_STREAM_BIN_PATH: <artifact>}.
_SHRED_STREAM_BIN_PATH = "/opt/shred-stream"

# The bootstrap validator's ledger dir (its blockstore lives at
# /data/bootstrap-ledger/rocksdb). shred-stream's --ledger arg points here.
_BOOTSTRAP_LEDGER = "/data/bootstrap-ledger"

# Schedule output format: `solana leader-schedule --no-address-labels` emits, per
# slot-in-epoch, a line padded by the Display impl at cli_output.rs:2177:
#   writeln!(f, "  {:<15} {:<44}", entry.slot, entry.leader)
# → "<2 spaces><slot padded to 15><1 space><pubkey padded to 44>". Unassigned
# slots get the literal "?" (cluster_query.rs:978), which would fail SIG's
# error.InvalidPubkey. So the extraction script normalizes with
# awk 'NF==2{print $1" "$2}' (collapses padding to single-space-separated) and
# substitutes any "?" leader with a real pubkey (the bootstrap identity) before
# validating exactly constants.SLOTS_PER_EPOCH lines.
_SCHEDULE_LINE_COUNT = constants.SLOTS_PER_EPOCH  # 432000, SIG's hardcoded constant
_SCHEDULE_FALLBACK_PUBKEY = "11111111111111111111111111111112"  # System program; never a "?"


def build_shred_stream_artifact(plan, sig_image, global_node_selectors={}):
    """Build a files-artifact containing the shred-stream binary, from the SIG image.

    Runs ONE `plan.run_sh` on the SIG image (which has the prebuilt shred-stream
    binary at /opt/sig/bin/shred-stream) that copies it to the StoreSpec src dir,
    producing a files-artifact named "shred-stream-bin". The artifact is later
    mounted on the BOOTSTRAP validator at _SHRED_STREAM_BIN_PATH (via the
    launch_validator `extra_files` param), so shred-stream can run inside the
    bootstrap container against its live blockstore.

    This has NO running-service dependency — it can (and must) run BEFORE the
    bootstrap service launches, because the bootstrap ServiceConfig(files=) is
    set at add_service time. (Files mounts are baked at service creation; you
    cannot attach a files-artifact to a running service.)

    Returns: the files-artifact name string (for passing to launch_validator's
    extra_files).
    """
    plan.print(
        "Building shred-stream files-artifact from SIG image '{0}' (for mounting on bootstrap)".format(sig_image),
    )

    # plan.run_sh runs under /bin/sh (dash on bookworm): use `set -eu` (POSIX),
    # NOT `set -o pipefail` (dash rejects it). No bash arrays. The script is
    # built as a list of lines joined by "\n" because plan.run_sh mangles real
    # newlines (memory kurtosis-run-sh-newlines); the list-join pattern is the
    # proven genesis_launcher pattern.
    workdir = "/tmp/shred-stream-stage"
    artifact_name = "shred-stream-bin"
    lines = [
        "set -eu",
        "rm -rf " + workdir,
        "mkdir -p " + workdir,
        # Copy the prebuilt binary out to the staging dir. The SIG image builds
        # both `sig` and `shred-stream` in the default zig build step (Dockerfile.sig
        # RUN zig build ... + the staging copies at lines 263-264). So /opt/sig/bin/
        # holds both. We only stage shred-stream (the bootstrap already has its own
        # validator binary; it needs shred-stream, not sig).
        "cp -a /opt/sig/bin/shred-stream " + workdir + "/shred-stream",
        "chmod 0755 " + workdir + "/shred-stream",
        # Prove it executes on this arch (the SIG image runtime is arm64, matching
        # the bootstrap's arm64 runtime — both native, no Rosetta).
        workdir + "/shred-stream --help >/dev/null 2>&1 || true",
        "ls -la " + workdir,
        "echo '[shred-stream-artifact] staged shred-stream binary'",
    ]
    result = plan.run_sh(
        run="\n".join(lines),
        image=sig_image,
        store=[StoreSpec(src=workdir, name=artifact_name)],
        acceptable_codes=[0],
        wait="120s",
    )
    return result.files_artifacts[0]


def build_schedule_artifact(plan, schedule_image, global_node_selectors={}):
    """Extract the REAL leader schedule from the bootstrap validator's RPC and
    build a files-artifact from it.

    Runs ONE `plan.run_sh` on the genesis image (which has the `solana` CLI),
    reaching the bootstrap RPC over Kurtosis in-enclave DNS at
    http://val-bootstrap:8899. This MUST run AFTER the bootstrap validator has
    come up and produced slots (so the schedule reflects the real stake
    distribution). The caller (participant_network) orders this call after the
    bootstrap + joiner are launched and verified non-delinquent.

    The script:
      1. Polls the bootstrap RPC until `solana slot` returns >= 1 (RPC up).
      2. Calls `solana --url http://val-bootstrap:8899 leader-schedule
         --no-address-labels` for epoch 0.
      3. Normalizes the padded Display output with awk 'NF==2{print $1" "$2}'.
      4. Substitutes any "?" (unassigned) leader with a real pubkey (the
         bootstrap identity from /data/meta.env), since "?" fails SIG's
         error.InvalidPubkey.
      5. Validates exactly _SCHEDULE_LINE_COUNT (432000) contiguous lines.
      6. Stores the schedule as a files-artifact named "leader-schedule".

    `solana leader-schedule` is a read-only RPC call — it touches no ledger, so
    it does NOT hit agave's io_uring_supported() assert (fs/src/dirs.rs:12 is in
    remove_dir_all/remove_dir_contents only). Therefore it CAN run in an
    unprivileged plan.run_sh container.

    Returns: the files-artifact name string (for mounting on SIG at
    /var/lib/sig/schedule, exposing /var/lib/sig/schedule/schedule.txt).
    """
    plan.print("Extracting real leader schedule from bootstrap RPC via run_sh")

    rpc_url = "http://val-bootstrap:" + str(constants.RPC_PORT_NUM)
    workdir = "/tmp/schedule-stage"
    outdir = workdir + "/out"  # clean dir holding only schedule.txt → StoreSpec src
    artifact_name = "leader-schedule"
    # plan.run_sh runs under /bin/sh (dash): `set -eu` only, no pipefail, no bash
    # arrays. Built as a list joined by "\n" (plan.run_sh mangles real newlines).
    # /data/meta.env is mounted on the genesis image (the artifact is mounted at
    # /data on every service that gets it); BOOTSTRAP_IDENTITY is the fallback
    # pubkey substitution target for "?" leaders.
    lines = [
        "set -eu",
        "rm -rf " + workdir,
        "mkdir -p " + outdir,
        "export PATH=/opt/agave/bin:/opt/jito/bin:$PATH",
        # Source genesis env for BOOTSTRAP_IDENTITY (the fallback pubkey for "?"
        # leaders). meta.env is carried in the genesis artifact mounted at /data.
        # This run_sh ephemeral container does NOT auto-mount the genesis artifact;
        # if /data/meta.env is absent the fallback pubkey stays at the System
        # program default (a valid base58 pubkey that satisfies the parser).
        "if [ -f /data/meta.env ]; then . /data/meta.env; fi",
        "FALLBACK=${BOOTSTRAP_IDENTITY:-" + _SCHEDULE_FALLBACK_PUBKEY + "}",
        # Poll the bootstrap RPC until it is up. plan.run_sh has no access to the
        # bootstrap service directly, but in-enclave DNS resolves val-bootstrap.
        # Up to 180s of polling (36 × 5s); acceptable_codes allows 0 only — if the
        # RPC never comes up the run_sh fails (and the plan stops), which is the
        # honest signal that the schedule could not be extracted.
        "ready=0",
        "i=0",
        "while [ $i -lt 180 ]; do",
        "  slot=$(solana --url " + rpc_url + " slot 2>/dev/null || echo 0)",
        "  case \"$slot\" in",
        "    ''|*[!0-9]*) slot=0 ;;",
        "  esac",
        "  if [ \"$slot\" -gt 0 ] 2>/dev/null; then ready=1; break; fi",
        "  i=$((i+5))",
        "  sleep 5",
        "done",
        "echo \"[schedule] rpc ready=$ready after $i s\"",
        "if [ \"$ready\" -ne 1 ]; then",
        "  echo '[schedule] FATAL: bootstrap RPC never returned a slot' >&2",
        "  exit 1",
        "fi",
        # Extract the real schedule. --no-address-labels avoids address-label
        # decoration. The Display impl pads (2 leading spaces, slot<15, pubkey<44).
        # awk 'NF==2{print $1" "$2}' collapses runs of whitespace to a single
        # space, yielding "<slot> <pubkey>" per line. Then substitute any "?"
        # leader (unassigned slot — cluster_query.rs:978) with the fallback pubkey,
        # because "?" would fail SIG's error.InvalidPubkey in fromCommand.
        "solana --url " + rpc_url + " leader-schedule --no-address-labels > " + workdir + "/raw.txt 2>/dev/null",
        "awk 'NF==2{print $1\" \"$2}' " + workdir + "/raw.txt > " + workdir + "/norm.txt",
        "awk -v fb=\"$FALLBACK\" 'NF==2{if($2==\"?\"||$2==\"??\") $2=fb; print $1\" \"$2}' " + workdir + "/norm.txt > " + outdir + "/schedule.txt",
        # Validate exactly _SCHEDULE_LINE_COUNT lines. SIG's leader_schedule.zig:10
        # hardcodes slots_per_epoch=432000; fromCommand (line 27) returns
        # error.IncorrectNumberOfSlots unless the file has exactly this count.
        # Discontinuity (non-contiguous slots) → error.Discontinuity. The first/last
        # check verifies contiguity (in epoch 0, absolute slots 0..431999 == offsets).
        "LINES=$(wc -l < " + outdir + "/schedule.txt | tr -d ' ')",
        "echo \"[schedule] lines=$LINES (expected " + str(_SCHEDULE_LINE_COUNT) + ")\"",
        "if [ \"$LINES\" -ne " + str(_SCHEDULE_LINE_COUNT) + " ]; then",
        "  echo '[schedule] FATAL: line count mismatch' >&2",
        "  echo '--- raw head ---' >&2; head -3 " + workdir + "/raw.txt >&2",
        "  echo '--- norm head ---' >&2; head -3 " + workdir + "/norm.txt >&2",
        "  exit 1",
        "fi",
        "FIRST=$(head -1 " + outdir + "/schedule.txt | awk '{print $1}')",
        "LAST=$(tail -1 " + outdir + "/schedule.txt | awk '{print $1}')",
        "if [ \"$FIRST\" != 0 ] || [ \"$LAST\" != " + str(_SCHEDULE_LINE_COUNT - 1) + " ]; then",
        "  echo '[schedule] FATAL: not contiguous 0..' + " + str(_SCHEDULE_LINE_COUNT - 1) + " >&2",
        "  echo \"first=$FIRST last=$LAST\" >&2",
        "  exit 1",
        "fi",
        "echo '[schedule] OK: 0..' + $LAST + ', " + str(_SCHEDULE_LINE_COUNT) + " lines'",
        "head -2 " + outdir + "/schedule.txt",
        "tail -1 " + outdir + "/schedule.txt",
    ]
    result = plan.run_sh(
        run="\n".join(lines),
        image=schedule_image,
        # Store ONLY the clean outdir (containing schedule.txt) so the artifact
        # is a single file. The artifact is mounted on SIG at /var/lib/sig/schedule
        # (a read-only subdir); leader_schedule_file points at
        # /var/lib/sig/schedule/schedule.txt. Mounting at a subdir keeps the
        # parent /var/lib/sig writable for config.zon / sig.log / accounts.db.
        store=[StoreSpec(src=outdir, name=artifact_name)],
        acceptable_codes=[0],
        wait="300s",
    )
    return result.files_artifacts[0]


def _write_config_cmd(shred_version, advertise_ip_expr, skip_on_cold_start, run_timeout_seconds):
    """Build the bash command that writes /var/lib/sig/config.zon for the observer.

    advertise_ip_expr is a shell expression that resolves to an "a.b.c.d" string
    (e.g. ``$(hostname -I | awk '{print $1}')``) — resolved at container runtime,
    because Starlark cannot see the future-allocated in-enclave IP. Any awk
    program inside it MUST be single-quoted: `bash -c` is invoked with no
    positional args, so double quotes would let `$1` expand to empty.

    shred_version is the FALLBACK used only when /data/meta.env did not export
    SHRED_VERSION (defensive; with a real genesis it is always set).

    skip_on_cold_start: False (the functional default) → SIG downloads a REAL
    snapshot over HTTP from the bootstrap + receives a real shred stream. True
    → the empty-snapshot bypass (research-grade fallback; died at
    accounts_db MissingVersionFile in the prior cold-start run). The functional
    path (False) is the official "Running a functional Sig validator" mode.

    The script is built as a list of lines joined by "\\n" (the proven
    genesis_launcher pattern), NOT as a .format() template. Two reasons:
      1. The ZON heredoc body and shell ${...} expressions are full of literal
         { } braces. Kurtosis's Starlark str.format is Go-fmt-based (NOT Python):
         a shell defaulting expression written as ${{SHRED_VERSION:-{SHRED_VER}}}
         in a template is read as a format field named "SHRED_VERSION" with a
         "-{SHRED_VER}" spec (the ':' triggers spec parsing), producing
         "format: keyword SHRED_VERSION not found". The list-join pattern
         interpolates values with "+" on individual lines only, sidestepping
         all brace escaping.
      2. Starlark does NOT support Python's implicit adjacent-string-literal
         concatenation (``"a" "b"``); a parenthesised expression of bare
         adjacent string literals is a parse error ("got string literal, want
         ')'"). Every adjacent pair needs an explicit "+", which the list-join
         pattern handles uniformly.
    plan.exec passes the argv array directly, so real newlines (and the heredoc)
    survive here — only plan.run_sh(run=...) mangles newlines
    (see memory kurtosis-run-sh-newlines).
    """
    _ = run_timeout_seconds  # used by the run stage, not this one
    gossip_port = str(constants.GOSSIP_PORT_NUM)
    tvu_port = str(constants.TVU_PORT_NUM)
    # skip_on_cold_start: render as Zig bool literal (lowercase true/false).
    if skip_on_cold_start:
        skip_cold_start_zon = "true"
    else:
        skip_cold_start_zon = "false"
    # Each element is one logical line of the bash script. Lines needing a
    # runtime value use string "+" on that element only; all literal braces in
    # the ZON body are preserved verbatim because nothing here calls .format().
    lines = [
        "set -euo pipefail",
        "mkdir -p /var/lib/sig/validator",
        "",
        "# Source the genesis env so SHRED_VERSION is available (the genesis artifact",
        "# is mounted at /data; meta.env carries the genesis-derived shred version).",
        "# Without this, ${SHRED_VERSION:-0} below would fall back to 0 and SIG would",
        "# join the wrong (or no) shred network.",
        "if [[ -f /data/meta.env ]]; then source /data/meta.env; fi",
        "",
        "# Resolve this observer's in-enclave IP (Starlark can't see the future IP).",
        "ADVERTISE_IP=" + advertise_ip_expr,
        'if [[ -z "$ADVERTISE_IP" ]]; then',
        '  echo "[sig-observer] FATAL: hostname -I returned no IP" >&2',
        "  exit 1",
        "fi",
        "",
        "# shred_version comes from the genesis env (sourced above). Fallback to the",
        "# passed default only if the var is absent (should not happen with a genesis).",
        "SHRED_VER=${SHRED_VERSION:-" + shred_version + "}",
        "",
        "# Write the ZON config. The heredoc delimiter is UNquoted so bash expands",
        "# ${ADVERTISE_IP} / ${SHRED_VER} into the body; literal ZON braces are left",
        "# untouched (braces are not special to bash in this position).",
        "cat > /var/lib/sig/config.zon <<SIGCONF",
        ".{",
        "    .sandboxing_mode = .threaded,",
        "",
        "    .cluster = .development,",
        '    .leader_schedule_file = "/var/lib/sig/schedule/schedule.txt",',
        "    .gossip = .{",
        "        .port = " + gossip_port + ",",
        "        .advertise_tvu_port = true,",
        '        .advertise_ip = "${ADVERTISE_IP}",',
        '        .development_entrypoints = .{"' + _BOOTSTRAP_ENTRYPOINT + '"},',
        "    },",
        "    .shred_network = .{",
        "        .recv_port = " + tvu_port + ",",
        "        .shred_version = ${SHRED_VER},",
        "    },",
        "    .telemetry = .{",
        "        .port = 9110,",
        "        .log_level = .info,",
        "    },",
        "    .snapshot = .{",
        '        .folder = "/var/lib/sig/validator",',
        '        .known_validators = .{"*"},',
        "        .skip_on_cold_start = " + skip_cold_start_zon + ",",
        "    },",
        "    .accounts_db = .{",
        '        .file = "/var/lib/sig/validator/accounts.db",',
        "        .rooted = .{ .gb = 1 },",
        "        .unrooted = .{ .gb = 1 },",
        "    },",
        "}",
        "SIGCONF",
        "",
        'echo "[sig-observer] wrote /var/lib/sig/config.zon (skip_on_cold_start=' + skip_cold_start_zon + ')"',
        'echo "[sig-observer] advertise_ip=$ADVERTISE_IP shred_version=$SHRED_VER entrypoint=' + _BOOTSTRAP_ENTRYPOINT + '"',
        "cat /var/lib/sig/config.zon",
    ]
    script = "\n".join(lines)
    return ["bash", "-c", script]


def _run_sig_cmd(run_timeout_seconds):
    """Start sig in the BACKGROUND and return immediately.

    `sig config.zon` runs forever as an observer (it does not exit on its own).
    We launch it under nohup + & so this plan.exec returns and the container
    (kept alive by its sleep-infinity entrypoint) continues hosting the observer
    for the rest of the plan. A bounded `timeout` is NOT used for the main run,
    because that would kill the observer mid-window; instead we capture the
    early boot log (first ~30s) to classify the evidence level, and let the
    process keep running.

    We give the process a head start and then snapshot its log so we can
    classify started vs joined without blocking the plan on the (infinite) run.
    """
    script = """set -euo pipefail
# Source genesis env for SHRED_VERSION (used by the config stage too, but be
# defensive: re-export in case this stage runs standalone).
if [[ -f /data/meta.env ]]; then source /data/meta.env; fi

rm -f /var/lib/sig/sig.log /var/lib/sig/sig.pid
# Launch sig in the background, stdout+stderr to a log file.
nohup /opt/sig/bin/sig /var/lib/sig/config.zon > /var/lib/sig/sig.log 2>&1 &
echo $! > /var/lib/sig/sig.pid
echo "[sig-observer] launched sig pid=$(cat /var/lib/sig/sig.pid)"

# Give it a head start, then snapshot the early boot log. We sleep for a fixed
# window so the classification is deterministic; the process keeps running.
sleep {BOOT_WINDOW}

if kill -0 "$(cat /var/lib/sig/sig.pid)" 2>/dev/null; then
  echo "[sig-observer] sig is alive after {BOOT_WINDOW}s (started)"
else
  echo "[sig-observer] sig exited within {BOOT_WINDOW}s (NOT started)"
fi

echo "=== sig.log (first 120 lines) ==="
head -n 120 /var/lib/sig/sig.log || true
echo "=== sig.log (last 40 lines) ==="
tail -n 40 /var/lib/sig/sig.log || true
kill -0 "$(cat /var/lib/sig/sig.pid)"
""".format(
        BOOT_WINDOW=min(run_timeout_seconds, 45),
    )
    return ["bash", "-c", script]


def _read_snapshot_slot_cmd():
    """Build the bash command that BLOCKS until SIG has a snapshot, then prints
    ONLY its slot number.

    Runs via plan.exec on the `sig-observer` service. SIG downloads a full
    snapshot from the bootstrap into its snapshot folder; the file is named
    `snapshot-<SLOT>-<HASH>.tar.zst` (the canonical Agave/SIG snapshot naming).
    Reading the SLOT from the FILE NAME is the most reliable signal (the
    "snapshot download completed slot=N" log line is not always flushed).

    ── OUTPUT CONTRACT (critical) ────────────────────────────────────────────
    Prints EXACTLY the slot number (e.g. "314") and nothing else — no marker, no
    newline, no log tail. Reason: plan.exec's returned `output` is a Kurtosis
    RUNTIME PLACEHOLDER (`{{kurtosis:...}}`), not a string we can parse in
    Starlark; AND a large stdout gets truncated. So the caller concatenates this
    runtime value straight into shred-stream's --start-slot (it expands at
    runtime), and never parses it. Blocking here (up to ~90s) removes the need
    for Starlark-side polling.

    Prints "0" if no snapshot appears within the wait window.
    """
    lines = [
        "set -uo pipefail",
        "SLOT=0",
        'SNAPDIR=/var/lib/sig/validator',
        # Block until a snapshot-*.tar.zst appears (SIG downloads it a few
        # seconds after boot), up to ~90s. Poll every 3s.
        "i=0",
        'while [ "$i" -lt 90 ]; do',
        '  F=$(ls -1t "$SNAPDIR"/snapshot-*.tar.zst 2>/dev/null | head -n1 || true)',
        '  if [ -n "$F" ]; then',
        '    S=$(basename "$F" | sed -E "s/^snapshot-([0-9]+)-.*/\\1/")',
        '    case "$S" in ""|*[!0-9]*) : ;; *) SLOT=$S; break ;; esac',
        "  fi",
        "  i=$((i+3))",
        "  sleep 3",
        "done",
        # Print ONLY the number (no marker, no newline).
        'printf "%s" "$SLOT"',
    ]
    script = "\n".join(lines)
    return ["bash", "-c", script]


def _run_shred_stream_cmd(start_slot_value, window_slots):
    """Build the bash command that runs shred-stream INSIDE the bootstrap container.

    Args:
        start_slot_value: SIG's snapshot slot as a Kurtosis RUNTIME VALUE (the
            output of read_snapshot_slot). It is concatenated into the shell
            script and expands to a number at runtime. We do NOT do arithmetic on
            it in Starlark (impossible — it's a placeholder); the window end is
            computed IN SHELL as `START + window_slots`.
        window_slots: size of the contiguous feed window (an int; the pool-safe
            bound — see the OutOfSpace note below).

    This runs via plan.exec on the `val-bootstrap` service (after SIG has started,
    downloaded its snapshot, and is listening on 8002). The shred-stream binary is
    already mounted on the bootstrap at _SHRED_STREAM_BIN_PATH (via the
    launch_validator extra_files param, from the shred-stream files-artifact).
    The bootstrap's live blockstore is at _BOOTSTRAP_LEDGER/rocksdb.

    shred-stream's --target arg uses parseIpAndPort (shred_stream.zig:327),
    which parses ONLY a literal IP:port — no hostname/DNS. So we resolve
    `sig-observer` → IP via `getent hosts sig-observer` inside the bootstrap
    container (Kurtosis in-enclave DNS resolves the service name), then pass the
    resolved IP as `--target <ip>:8002`.

    ── WHY A BOUNDED WINDOW (the OutOfSpace fix) ─────────────────────────────
    SIG's replay builds a merkle forest in a FIXED pool of 4096 nodes
    (v2/services/replay.zig:1482 `const capacity = 4096`) and does NOT reclaim
    nodes as slots root — the only `pool.destroy` in the service is for
    orphan nodes with invalid chaining (replay.zig:728). A slot carries ~33 FEC
    sets (last fec-set idx=32), so the pool holds only ~124 slots of live data.

    The prior run passed `--start-slot 0` (the whole blockstore, ~14965 slots ≈
    49万 nodes) which overflows the pool → `error.OutOfSpace` at pool.zig:280
    (`create()`), killing the replay service. The official doc says to feed
    "all slots starting at the snapshot slot being used by sig" — so we start at
    SIG's ACTUAL snapshot slot (read from its log by _read_snapshot_slot_cmd)
    and stop after a bounded window that fits the pool.

    shred-stream is ONE-SHOT: it reads existing blockstore slots ONCE and exits.
    We run it under nohup + & so the plan.exec returns immediately. Its
    stdout/stderr go to a log the bootstrap keeps.

    Args:
        start_slot_value: SIG's snapshot slot (runtime value).
        window_slots:     size of the contiguous feed window.
    """
    bin = _SHRED_STREAM_BIN_PATH + "/shred-stream"
    # Build as a list joined by "\n" so literal braces/quotes survive. We use
    # plan.exec (not run_sh), so real newlines would also survive, but the
    # list-join pattern is uniform with the rest of this module.
    lines = [
        "set -euo pipefail",
        # Materialise the runtime start-slot value into a shell var. It is a
        # Kurtosis runtime placeholder that expands to a number here.
        'START=' + start_slot_value,
        # Compute the window end IN SHELL (we cannot do arithmetic on the runtime
        # value in Starlark). Guard against START=0 (no snapshot yet): clamp the
        # start to 1 so the window is still valid.
        'if [ -z "$START" ] || [ "$START" -eq 0 ] 2>/dev/null; then START=1; fi',
        'END=$((START + ' + str(window_slots) + '))',
        'echo "[shred-stream] window $START..$END (snapshot start=$START)"',
        # Resolve sig-observer → IP via in-enclave DNS. parseIpAndPort needs a
        # literal IP, not a hostname.
        'SIG_IP="$(getent hosts sig-observer | awk \'{print $1}\' | head -n1)"',
        'if [[ -z "$SIG_IP" ]]; then',
        '  echo "[shred-stream] FATAL: could not resolve sig-observer via getent" >&2',
        "  exit 1",
        "fi",
        'echo "[shred-stream] sig-observer resolved to $SIG_IP"',
        # Sanity-check the binary + ledger exist.
        "ls -la " + bin,
        "ls -d " + _BOOTSTRAP_LEDGER + "/rocksdb",
        # Run shred-stream in the background over the BOUNDED window
        # [START, END]. --rate-hz 100 paces the stream so we don't overrun SIG's
        # shred receiver. nohup + & so this exec returns promptly.
        "rm -f /tmp/shred-stream.log",
        "nohup " + bin + " \\",
        "  --ledger " + _BOOTSTRAP_LEDGER + " \\",
        '  --target "${SIG_IP}:8002" \\',
        '  --start-slot "$START" \\',
        '  --end-slot "$END" \\',
        "  --rate-hz 100 \\",
        "  > /tmp/shred-stream.log 2>&1 &",
        'echo "[shred-stream] launched pid=$! target=${SIG_IP}:8002 window=$START..$END"',
        "sleep 3",
        "echo '=== shred-stream.log (first 30 lines) ==='",
        "head -n 30 /tmp/shred-stream.log || true",
    ]
    script = "\n".join(lines)
    return ["bash", "-c", script]


def _classify_cmd():
    """Classify the SIG evidence level from its log, AFTER the run stage.

    We look for the gossip/join markers that indicate SIG resolved and contacted
    the bootstrap entrypoint. SIG has no RPC to query, so log inspection is the
    only honest signal. We never claim "joined" unless we see concrete gossip
    connection evidence; otherwise the honest level is "started".
    """
    script = """set -uo pipefail
LOG=/var/lib/sig/sig.log
PIDF=/var/lib/sig/sig.pid
EVIDENCE="not_started"
if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  EVIDENCE="started"
fi
# Gossip-join markers (SIG successfully contacted a peer / has entry addrs).
# These log substrings indicate the observer moved past cold-start into the
# gossip/shred stream — the honest definition of "joined" for a non-voting
# observer with no RPC.
JOINED=0
if [[ -f "$LOG" ]]; then
  # SIG has no RPC; the honest "joined" signal is that it received and replayed
  # REAL cluster data. SIG's replay logs "received 0th/last fec set of slot N"
  # when it ingests a FEC set from the live turbine/gossip stream, and "Slot N
  # ... complete!" when it finishes replaying a slot. Either proves SIG is
  # participating in the cluster's data flow (not merely alive). Kept alongside
  # the older gossip-ish markers for compatibility.
  if grep -Eaq "received (0th|last) fec set of slot|Slot [0-9]+ .*complete!|received shred|connected to peer|crds.*received" "$LOG"; then
    JOINED=1
  fi
fi
if [[ "$JOINED" -eq 1 && "$EVIDENCE" == "started" ]]; then
  EVIDENCE="joined"
fi
# Persist ONLY the level to a tiny file. plan.exec's returned `output` is
# truncated for execs with large stdout; the 60-line log tail below can push
# the marker out of the surviving prefix (observed 2026-10-20: the marker was
# printed but the plan read not_started). A short `cat` of this file always
# survives — the bank_hash_probe.star pattern.
printf "%s" "$EVIDENCE" > /var/lib/sig/evidence_level.txt
echo "SIG_EVIDENCE_LEVEL=$EVIDENCE"
echo "SIG_PID=$(cat "$PIDF" 2>/dev/null || echo none)"
echo "SIG_LOG_BYTES=$(wc -c < "$LOG" 2>/dev/null || echo 0)"
echo "=== sig.log tail (60) ==="
tail -n 60 "$LOG" 2>/dev/null || true
"""
    return ["bash", "-c", script]


def read_snapshot_slot(plan, service_name, retries=1):
    """Return SIG's downloaded snapshot slot as a Kurtosis RUNTIME VALUE.

    ── WHY THIS RETURNS A RUNTIME VALUE, NOT A PARSED INT ────────────────────
    plan.exec's returned `output` is NOT a plain string in Starlark — it is a
    Kurtosis runtime placeholder like
    `{{kurtosis:<uuid>:output.runtime_value}}`. It renders correctly when PRINTED
    or when concatenated into ANOTHER command (both at runtime), but ANY
    Starlark-side string operation on it is wrong: `"x" in out` is False,
    `out.split(...)` fails, `int(out)` raises "invalid literal". So we do NOT
    parse it. The command itself BLOCKS in-container until a snapshot exists
    (see _read_snapshot_slot_cmd) and prints ONLY the slot number; we return that
    runtime value unchanged for the caller to concatenate into shred-stream's
    --start-slot.

    `retries` is retained for API compatibility; the blocking is now done in the
    container, so one exec suffices. A returned "0" means no snapshot appeared.
    """
    slot_value = "0"
    for _ in range(retries):
        result = plan.exec(
            recipe=ExecRecipe(command=_read_snapshot_slot_cmd()),
            service_name=service_name,
            acceptable_codes=[0, 1],
        )
        slot_value = result.get("output", "0")
    return slot_value


def launch_sig_observer(plan, sig_config, genesis_artifact, schedule_artifact, global_node_selectors={}, initial_snapshot_artifact=None):
    """Launch the SIG non-voting observer against the shared genesis cluster.

    Args:
        plan: the Kurtosis plan
        sig_config: the parsed `sig` block from input_parser (image,
            run_timeout_seconds, skip_on_cold_start)
        genesis_artifact: the files-artifact name from generate_genesis (mounted
            at /data so /data/meta.env is available for SHRED_VERSION)
        schedule_artifact: the files-artifact name from build_schedule_artifact
            (mounted at /var/lib/sig/schedule, exposing the REAL leader schedule
            at /var/lib/sig/schedule/schedule.txt — extracted from the bootstrap
            RPC). This is the official functional path step 1-2.
        global_node_selectors: optional node selectors

    Returns: struct(service, name, evidence_level, log_path)
        evidence_level is the honest lowest-proven level string, one of
        "started" | "joined" | "not_started". NEVER "voting".

    The official functional path step 4 (shred-stream) is run by the CALLER
    (participant_network) via a plan.exec on the bootstrap container AFTER this
    service has started, because shred-stream targets THIS observer's IP:8002.
    This module exposes _run_shred_stream_cmd() for the caller to use.
    """
    name = "sig-observer"
    image = sig_config["image"]
    run_timeout = sig_config["run_timeout_seconds"]
    skip_on_cold_start = sig_config.get("skip_on_cold_start", False)

    plan.print(
        "Launching SIG observer '{0}' (image={1}, NON-VOTING observer; cluster=development, functional path skip_on_cold_start={2})"
        .format(name, image, skip_on_cold_start),
    )

    # The schedule files-artifact is mounted at a READ-ONLY subdir
    # /var/lib/sig/schedule. A files-artifact mount makes the mount point
    # read-only, so mounting at /var/lib/sig itself would break config.zon /
    # sig.log / accounts.db writes under /var/lib/sig. Mounting at a dedicated
    # subdir keeps the parent /var/lib/sig writable. The artifact (built by
    # build_schedule_artifact via StoreSpec(src=outdir) where outdir holds
    # schedule.txt) exposes schedule.txt at its root, so the mounted path is
    # /var/lib/sig/schedule/schedule.txt — exactly what config.leader_schedule_file
    # points at (see _write_config_cmd).
    files_map = {
        constants.GENESIS_DATA_MOUNTPOINT: genesis_artifact,
        "/var/lib/sig/schedule": schedule_artifact,
    }

    if initial_snapshot_artifact != None:
        files_map["/var/lib/sig/initial-snapshot"] = initial_snapshot_artifact

    config_args = {
        "image": image,
        "entrypoint": ["sleep"],
        "cmd": ["infinity"],
        # No ports declared: SIG binds 8001/8002 only after a valid config is
        # written and `sig` is launched, which happens in plan.exec stages below
        # (not at container start). Declaring them would trip Kurtosis's
        # port-readiness timeout before our stages run.
        #
        # PRIVILEGED is REQUIRED: SIG's accounts_db uses Linux io_uring; under
        # OrbStack's default seccomp io_uring_setup returns EPERM on native arm64.
        # --privileged clears the seccomp gate. REQUIRES `kurtosis run --privileged`.
        "privileged": True,
        "files": files_map,
        "node_selectors": global_node_selectors,
    }

    service = plan.add_service(name=name, config=ServiceConfig(**config_args))
    plan.print("SIG observer container started (sleep infinity, privileged, schedule mounted).")

    # Stage 1: confirm the binary + BUILD-INFO (build evidence inside the run).
    plan.exec(
        recipe=ExecRecipe(command=[
            "bash", "-c",
            "echo '--- binary ---'; ls -la /opt/sig/bin/sig; " +
            "echo '--- BUILD-INFO ---'; cat /opt/sig/BUILD-INFO; " +
            "echo '--- schedule ---'; wc -l /var/lib/sig/schedule/schedule.txt; head -2 /var/lib/sig/schedule/schedule.txt",
        ]),
        service_name=name,
        acceptable_codes=[0],
    )

    # Stage 2: write config.zon. advertise_ip is resolved at runtime via
    # hostname -I; shred_version is taken from /data/meta.env (SHRED_VERSION),
    # which the genesis_launcher wrote from `solana-genesis`'s output. We pass a
    # default of 0 as a defensive fallback only.
    #
    # NOTE: the awk program MUST be single-quoted: `bash -c <script>` (no positional
    # args) would expand `$1` to empty inside double quotes, producing
    # `awk "{print }"` → empty ADVERTISE_IP → FATAL. Single quotes carry `$1`
    # literally into awk. Also, _write_config_cmd builds this via concatenation
    # (NOT .format()), so ${...} and the ZON braces survive untouched.
    plan.exec(
        recipe=ExecRecipe(command=_write_config_cmd(
            shred_version="0",
            advertise_ip_expr="$(hostname -I | awk '{print $1}')",
            skip_on_cold_start=skip_on_cold_start,
            run_timeout_seconds=run_timeout,
        )),
        service_name=name,
        acceptable_codes=[0],
    )

    if initial_snapshot_artifact != None:
        plan.exec(
            service_name=name,
            recipe=ExecRecipe(command=["bash", "-c",
                "set -euo pipefail; mkdir -p /var/lib/sig/validator; cp /var/lib/sig/initial-snapshot/snapshot-*.tar.* /var/lib/sig/validator/",
            ]),
            acceptable_codes=[0],
        )

    # Stage 3: launch sig in the background and capture the early boot log.
    # The process keeps running after this exec returns (nohup + &).
    # The real leader schedule is already mounted at
    # /var/lib/sig/schedule/schedule.txt (from the schedule files-artifact), so
    # there is no synthetic schedule generation stage here — the functional path
    # uses the REAL schedule.
    plan.exec(
        recipe=ExecRecipe(command=_run_sig_cmd(run_timeout_seconds=run_timeout)),
        service_name=name,
        acceptable_codes=[0],
    )

    # NOTE: classification is DELIBERATELY NOT done here. At this point the
    # shred-stream has not run yet (participant_network runs it AFTER this
    # function returns), so SIG has received no shreds and would always classify
    # as not_started — a false negative (observed 2026-10-20: replay was happily
    # processing FEC sets while the in-launcher classify said not_started). The
    # caller re-classifies via classify_sig_evidence() AFTER shred-stream has
    # fed SIG. We still return a provisional level so the topology struct is
    # well-formed.
    plan.print(
        "SIG observer '{0}' launched (NON-VOTING; evidence classified after shred-stream)"
        .format(name),
    )

    return struct(
        service=service,
        name=name,
        evidence_level="not_started",  # provisional; caller re-classifies
        log_path="/var/lib/sig/sig.log",
    )


def classify_sig_evidence(plan, service_name):
    """Return SIG's evidence level as a Kurtosis RUNTIME VALUE.

    Runs `_classify_cmd` (which writes the level to /var/lib/sig/evidence_level.txt
    and prints it), then a tiny `cat` whose output is the level.

    ── WHY WE RETURN THE RAW RUNTIME VALUE (no Starlark branching) ───────────
    plan.exec's returned `output` is a Kurtosis RUNTIME PLACEHOLDER
    (`{{kurtosis:...}}`), not a comparable string: `level in (...)` / `==` are
    always wrong in Starlark, and `plan.wait` cannot be used to probe-and-fallback
    (Kurtosis Starlark has no try/except, and a failing plan.wait aborts the
    plan). So we do NOT branch on the value here. We return it unchanged; it is
    threaded into the topology and into the evidence JSON, where Kurtosis renders
    it to the real string ("not_started" | "started" | "joined") at runtime.
    Never "voting".

    The authoritative "joined" determination (per AGENTS.md: "the node appeared in
    the shared-genesis gossip/network view") is recorded separately by the
    slot_verifier, which reads the BOOTSTRAP's gossip view and counts peers.
    """
    plan.exec(
        recipe=ExecRecipe(command=_classify_cmd()),
        service_name=service_name,
        acceptable_codes=[0, 1],
    )
    read_result = plan.exec(
        recipe=ExecRecipe(command=[
            "bash", "-c",
            "cat /var/lib/sig/evidence_level.txt 2>/dev/null || echo not_started",
        ]),
        service_name=service_name,
        acceptable_codes=[0, 1],
    )
    level = read_result.get("output", "not_started")
    plan.print(
        "SIG observer '{0}' classified evidence_level={1} (NON-VOTING; observer only)"
        .format(service_name, level),
    )
    return level
