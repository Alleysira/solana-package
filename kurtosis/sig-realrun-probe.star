# sig-realrun-probe.star
#
# Kurtosis package: probe the real `sig config.zon` run path in a Kurtosis
# container on THIS host (OrbStack), to capture honest machine-readable evidence
# of exactly where the SIG observer lands.
#
# RUNTIME PATH (proven 2026-09-29): use the NATIVE arm64 image
# (solana-diff/sig:v0.2.0-arm64) + a PRIVILEGED container.  SIG's accounts_db
# uses Linux io_uring (v2/lib/fio/writer.zig via Zig std IoUring.zig).
#   - x86_64 image (Rosetta): io_uring_setup returns ENOSYS even under
#     --privileged (Rosetta's syscall-translation layer does not translate
#     io_uring) — UNSOLVABLE; caps at `built` (accounts_db crashes at init).
#   - arm64 image (native): io_uring_setup returns EPERM under default seccomp,
#     but OK under --privileged (fd=3, features=0x3ffff).  Under --privileged ALL
#     services boot past io_uring: config parse, 19 shared-memory regions, net
#     binds 8001+8002, gossip STARTS (real identity, shred_version=4457,
#     testnet entrypoints), shred_receiver waits, snapshot starts, accounts_db
#     starts (writes journal, reads from snapshot).  Next gate: net sendto =>
#     WouldBlock (gossip to unreachable testnet entrypoints) — the expected
#     CLUSTER gate, not a host gate.
#
# EXPECTED OUTCOME under arm64 + --privileged (the run below):
#   - config parse (succeeds — config.zon is valid)
#   - leader schedule parse (succeeds — 432000-slot synthetic schedule)
#   - io_uring init (succeeds — accounts_db starts; this is the gate that
#     FAILED on the x86_64/Rosetta image with ENOSYS)
#   - gossip start + net sendto => WouldBlock (no reachable testnet entrypoint)
# Honest evidence level on this host: `started` (services boot past config parse
# AND past io_uring), never `joined`/`voting`.  `joined` needs a reachable
# cluster + real snapshot + shred stream.  `voting` is structurally impossible
# (SIG never votes).
#
# REQUIRES: `kurtosis run --privileged` (the CLI flag) so that
# ServiceConfig(privileged=True) takes effect.
#
# The container is started with a `sleep infinity` entrypoint so it stays alive
# for plan.exec; each stage is run and its exit code + output captured
# separately.

SIG_IMAGE = "solana-diff/sig:v0.2.0-arm64"

def _run_capture(plan, name, command, accept_codes = [0]):
    """Run a command in the sig container via plan.exec and print a labelled
    capture of its exit code + stderr/stdout."""
    result = plan.exec(
        recipe = ExecRecipe(command = command),
        service_name = "sig",
        acceptable_codes = accept_codes,
    )
    code = result["code"]
    out = result.get("output", "")
    err = result.get("error", "")
    plan.print("=== {0} (exit={1}) ===".format(name, code))
    if out != "":
        plan.print("STDOUT: " + out)
    if err != "":
        plan.print("STDERR: " + err)
    return code

def run(plan, image = SIG_IMAGE):
    """Deploy the sig container (kept alive) and probe the real run path."""
    config_args = {
        "image": image,
        "entrypoint": ["sleep"],
        "cmd": ["infinity"],
        # No ports declared in probe mode: nothing binds until sig runs with a
        # valid config. Avoids Kurtosis's port-readiness timeout.
        #
        # PRIVILEGED is REQUIRED on the arm64 image: SIG's accounts_db uses
        # io_uring, which OrbStack's default seccomp profile blocks with EPERM
        # (native arm64).  --privileged clears the seccomp gate so accounts_db
        # boots past io_uring init.  (On the x86_64/Rosetta image io_uring
        # returns ENOSYS even under --privileged — use arm64 for real runs.)
        # REQUIRES the `--privileged` CLI flag on `kurtosis run`.
        "privileged": True,
    }
    plan.add_service(name = "sig", config = ServiceConfig(**config_args))

    plan.print("SIG container started (probe mode, sleep infinity).")

    # Stage 1: confirm the binary + BUILD-INFO (build evidence).
    _run_capture(plan, "sig-binary-and-buildinfo", [
        "bash", "-c",
        "echo '--- binary ---'; ls -la /opt/sig/bin/sig; " +
        "echo '--- BUILD-INFO ---'; cat /opt/sig/BUILD-INFO; " +
        "echo '--- zig version (if present) ---'; /opt/zig/bin/zig version 2>/dev/null || echo '(zig not in runtime image)'",
    ])

    # Stage 2: write a config.zon for the observer probe.  Use `threaded`
    # sandboxing mode (single-process) to avoid the seccomp/fork gate that
    # `sandboxed` mode hits under container seccomp profiles.  Cluster =
    # testnet so getFromEcho tries real testnet entrypoints (which will fail/
    # timeout — the expected blocker on this host).
    _run_capture(plan, "write-config", ["bash", "-c", "mkdir -p /var/lib/sig/validator && cat > /var/lib/sig/config.zon <<'SIGCONF'\n.{\n    .sandboxing_mode = .threaded,\n\n    .cluster = .testnet,\n    .leader_schedule_file = \"/var/lib/sig/schedule.txt\",\n    .gossip = .{\n        .port = 8001,\n        .advertise_tvu_port = true,\n    },\n    .shred_network = .{\n        .recv_port = 8002,\n    },\n    .telemetry = .{\n        .port = 9110,\n        .log_level = .info,\n    },\n    .snapshot = .{\n        .folder = \"/var/lib/sig/validator\",\n        .known_validators = .{\"*\"},\n    },\n    .accounts_db = .{\n        .file = \"/var/lib/sig/validator/accounts.db\",\n        .rooted = .{ .gb = 8 },\n        .unrooted = .{ .gb = 8 },\n    },\n}\nSIGCONF\n"])

    # Stage 3: generate a 432000-slot leader schedule.  SIG's
    # LeaderSchedule.fromCommand requires EXACTLY 432000 contiguous
    # <slot> <pubkey> lines (slots_per_epoch = 432000).  We generate a
    # synthetic schedule with a dummy pubkey so the parse succeeds — this is
    # NOT a real leader schedule, just enough to get past schedule parse to the
    # next gate (gossip/snapshot).  Use a pure-shell generator (seq + awk) so it
    # works in the slim runtime image, which has NO python3.  The pubkey
    # 11111111111111111111111111111112 is a well-known Solana system-program
    # format; fromCommand only checks the count and base58 format here.
    _run_capture(plan, "generate-leader-schedule", ["bash", "-c", "seq 0 431999 | awk '{print $1\" 11111111111111111111111111111112\"}' > /var/lib/sig/schedule.txt; wc -l /var/lib/sig/schedule.txt; head -2 /var/lib/sig/schedule.txt; tail -1 /var/lib/sig/schedule.txt"])

    # Stage 4: run `sig config.zon` with a timeout.  EXPECTED to reach config
    # parse + service init, then block/fail at gossip getFromEcho (no reachable
    # entrypoint) or snapshot load (no snapshot).  accept [0,1,124,134,139] to
    # capture the failure rather than aborting the probe.
    _run_capture(plan, "sig-run", ["bash", "-c", "timeout 60 /opt/sig/bin/sig /var/lib/sig/config.zon 2>&1"], accept_codes = [0, 1, 124, 134, 139])

    plan.print(
        "Probe complete. On the arm64 image under --privileged, sig-run is " +
        "EXPECTED to reach config parse + service init AND boot past io_uring " +
        "(accounts_db starts) — the io_uring gate that ENOSYS'd on the x86_64/" +
        "Rosetta image is cleared by native arm64 + --privileged.  The next " +
        "gate is net sendto => WouldBlock (gossip to unreachable testnet " +
        "entrypoints) — the expected CLUSTER gate, not a host gate.  Honest " +
        "level on this host: `started` (services boot past config parse AND " +
        "past io_uring), never `joined`/`voting`. SIG is a NON-VOTING OBSERVER."
    )
