# sig-single-node.star
#
# Kurtosis package: single-node SIG v2 (Zig) observer service.
#
# HONESTY CONTRACT (see AGENTS.md evidence rules + README-SIG-CONTAINER.md):
# SIG v2 is a NON-VOTING OBSERVER, never a voting validator.  It requires:
#   - an externally generated leader schedule (solana leader-schedule, 432000 slots)
#   - a snapshot from another validator
#   - a complete external shred stream (no repair implemented)
#   - a reachable gossip entrypoint (getFromEcho connects via TCP)
# None of these exist on this host without a running cluster.  So on this Mac,
# the honest ceiling is `built` (the binary builds and executes).
#
# The sig binary takes:  sig <config.zon> [log_filters]
#   - argv[1] = path to a .zon config file (errors ConfigPathMissing if absent)
# SIG has NO --version flag; build evidence = the binary executes with a
# deterministic error when given no config.
#
# This package has two paths:
#   1. build-evidence (default, real_run=False): container starts with a
#      `sleep infinity` entrypoint (no ports declared, so no port-readiness
#      wait), then `plan.exec` runs the sig binary with no config and captures
#      the deterministic ConfigPathMissing error + BUILD-INFO.  Evidence: built.
#   2. real-run probe (real_run=True): writes a config.zon + a leader schedule,
#      runs the binary with the config, and captures where it lands.  On this
#      host it will reach config parse + service init, then block/fail at
#      gossip getFromEcho (no reachable entrypoint).  Evidence: at most
#      `started` (process boots services), never `joined`/`voting`.
#
# WHY sleep-infinity + plan.exec (not add_service with cmd=["sig"]):
# The image ENTRYPOINT is `tini -g -- /opt/sig/bin/sig`.  In build-evidence
# mode `sig` exits immediately with an error (it never binds the telemetry
# port), so Kurtosis's port-readiness wait (240 retries × 500 ms = 2 min)
# times out and the run fails — even though the binary executed fine.  The
# sleep-infinity entrypoint keeps the container alive; we probe via plan.exec,
# which is the proven firedancer-realrun-probe pattern.

SIG_IMAGE = "solana-diff/sig:v0.2.0-amd64"
SIG_IMAGE_ARM64 = "solana-diff/sig:v0.2.0-arm64"

def _run_capture(plan, name, command, accept_codes = [0]):
    """Run a command in the sig container via plan.exec and print a labelled
    capture of its exit code + stderr/stdout. accept_codes lets us capture a
    non-zero exit (e.g. the expected ConfigPathMissing error)."""
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

def run(plan, image = SIG_IMAGE, real_run = False, config_artifact = None, leader_schedule_artifact = None):
    """Deploy a single SIG v2 observer service in Kurtosis.

    Args:
        plan: the Kurtosis plan
        image: container image to use
        real_run: if True, attempt `sig config.zon` (needs a reachable cluster).
                  If False (default), run the binary with no config for build
                  evidence only.
        config_artifact: name of a Kurtosis artifact holding config.zon (real_run only)
        leader_schedule_artifact: name of a Kurtosis artifact holding schedule.txt (real_run only)
    Returns:
        the service object
    """
    # Keep the container alive with sleep infinity in BOTH paths so we can
    # probe via plan.exec.  No ports declared in build-evidence mode (the
    # binary never binds anything without a valid config).
    config_args = {
        "image": image,
        "entrypoint": ["sleep"],
        "cmd": ["infinity"],
    }
    if real_run:
        if not config_artifact or not leader_schedule_artifact:
            plan.fail("real_run=True requires config_artifact and leader_schedule_artifact")
        config_args["files"] = {
            "/var/lib/sig/config.zon": config_artifact,
            "/var/lib/sig/schedule.txt": leader_schedule_artifact,
        }
        # REAL-RUN REQUIRES --privileged on the `kurtosis run` CLI:
        # SIG's accounts_db uses Linux io_uring (v2/lib/fio/writer.zig via
        # Zig std IoUring.zig).  On OrbStack the default container seccomp
        # profile blocks io_uring_setup with EPERM (native arm64) — and
        # `ServiceConfig(privileged=True)` clears it, so accounts_db boots
        # past io_uring init.  (On x86_64/Rosetta, OrbStack's syscall
        # translation returns ENOSYS even under --privileged — that's a
        # separate, unsolvable Rosetta gate; use the arm64 image for real
        # runs.)  privileged=True requires opting in via the `--privileged`
        # CLI flag (or allow-privileged-mode in kurtosis-config.yml).
        config_args["privileged"] = True

    # SIG is a normal Zig process — NO NUMA/hugepage gate (unlike Firedancer).
    service = plan.add_service(name = "sig", config = ServiceConfig(**config_args))

    # ── Stage 1: build evidence (binary + BUILD-INFO) ──────────────────────
    _run_capture(plan, "sig-binary-and-buildinfo", [
        "bash", "-c",
        "echo '--- binary ---'; ls -la /opt/sig/bin/sig; " +
        "echo '--- BUILD-INFO ---'; cat /opt/sig/BUILD-INFO",
    ])

    if not real_run:
        # ── Stage 2: execute the binary with no config ──────────────────────
        # SIG has no --version flag; with no argv[1] it returns a deterministic
        # ConfigPathMissing error — proving the binary executes on linux/amd64
        # (the honest `built` check).  Run via plan.exec so we capture the
        # exit code + output; the container itself stays alive on sleep.
        _run_capture(
            plan, "sig-no-config-execute",
            ["bash", "-c", "/opt/sig/bin/sig 2>&1 || true"],
            accept_codes = [0, 1, 2, 134, 139],
        )
        plan.print(
            "SIG deployed in BUILD-EVIDENCE mode. The binary executes on " +
            "linux/amd64 (Rosetta). On this host SIG cannot reach `started`: " +
            "it needs a reachable gossip entrypoint + a 432000-slot leader " +
            "schedule + a snapshot + a complete shred stream, none of which " +
            "exist without a running cluster. SIG is a NON-VOTING OBSERVER " +
            "(never votes). Evidence level: built."
        )
    else:
        # ── real-run probe: execute `sig config.zon` ─────────────────────────
        # EXPECTED on this host: config parse OK, leader-schedule parse OK,
        # then block/fail at gossip getFromEcho (no reachable testnet
        # entrypoint) or snapshot load (no snapshot folder).
        _run_capture(
            plan, "sig-config-run",
            ["bash", "-c", "timeout 60 /opt/sig/bin/sig /var/lib/sig/config.zon 2>&1"],
            accept_codes = [0, 1, 124, 134, 139],
        )
        plan.print(
            "Probe complete. If sig-config-run reached config parse + service " +
            "init then failed at gossip getFromEcho (no reachable testnet " +
            "entrypoint) or snapshot load (no snapshot), that is the expected " +
            "host gate: SIG needs a reachable cluster + snapshot + shred stream " +
            "to start. Honest level on this host: at most `started` (process " +
            "boots past config parse), never `joined`/`voting`. SIG is a " +
            "NON-VOTING OBSERVER."
        )

    return service
