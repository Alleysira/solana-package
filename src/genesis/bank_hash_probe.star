# Bank-hash probe — capture the deterministic slot-0 bank hash.
#
# A two-validator dev cluster with 50/50 stake can deadlock unless both
# validators coordinate at slot 0: each must wait until the other is visible
# in gossip before starting PoH, so they build the SAME first fork and reach
# the 2/3 finalization threshold together. Solana does this coordination via
# `--wait-for-supermajority 0 --expected-bank-hash <hash>`: every validator
# waits until 100% of stake is seen in gossip, then verifies its own slot-0
# bank hash matches the expected one before voting.
#
# The slot-0 bank hash is deterministic for a given genesis (it is the hash of
# the genesis accounts state). `solana-genesis` does NOT print it (it prints
# the genesis *block*hash, a different value); only a running validator emits
# it as the `bank frozen: 0 hash: <H>` log line. So we boot a short-lived probe
# validator on a copy of the genesis ledger, capture that line, and stop it.
# This mirrors the proven `smoke-shared-genesis.sh:133-166` probe container.
#
# The probe MUST be privileged (add_service(privileged=True)), NOT a run_sh:
# agave 4.3.0 fs/src/dirs.rs:12 hard-asserts io_uring_supported() on Linux, and
# OrbStack's default seccomp makes io_uring_setup return EPERM in non-privileged
# containers. plan.run_sh containers are NOT privileged even under `kurtosis run
# --privileged` (verified: CapEff=0000000000000000, uid 1000) — only
# add_service(privileged=True) clears the seccomp gate.
#
# We use the bootstrap identity/vote/stake (from /data/meta.env) and a copy of
# the genesis ledger as the probe's own ledger. The probe does NOT gossip to
# the real cluster (no --entrypoint, --no-snapshot-fetch, --no-genesis-fetch);
# it only needs to boot far enough to freeze bank 0 and print the hash.

constants = import_module("../package_io/constants.star")

# The probe ledger subdir under /data (genesis_launcher copies the genesis
# ledger into this — matches smoke-shared-genesis.sh:97's probe-ledger).
_PROBE_LEDGER_SUBDIR = "probe-ledger"


def _probe_cmd():
    """Build the bash -c wrapper that boots the probe validator and prints BANK_HASH=.

    The probe boots agave-validator on a copy of the genesis ledger, waits up
    to ~30s for the `bank frozen: 0 hash:` line, prints `BANK_HASH=<hash>`, and
    exits. We run it under a bounded `timeout` so it never lingers as a second
    validator on the network (it has no --entrypoint and --no-snapshot-fetch,
    so it won't gossip-join, but we kill it explicitly to be safe).

    The script is built as a list of lines joined by "\\n" (the genesis_launcher
    pattern), NOT as a .format() template — the awk program and shell ${...}
    below are full of literal braces that .format() would try to interpret.
    """
    lines = [
        "set -uo pipefail",
        "export PATH=\"/opt/agave/bin:/opt/jito/bin:$PATH\"",
        "source /data/meta.env",
        "cd /data",
        "",
        "# Resolve this container's in-enclave IP (probe needs --bind-address).",
        'MY_IP="$(hostname -I | awk \'{print $1}\')"',
        'if [[ -z "$MY_IP" ]]; then echo "[probe] FATAL: hostname -I returned no IP" >&2; exit 1; fi',
        'echo "[probe] my_ip=$MY_IP"',
        "",
        "# Boot the probe validator on a genesis-ledger copy. It does NOT join",
        "# the real cluster (no --entrypoint; --no-snapshot/--genesis-fetch). It",
        "# only needs to reach bank-0 freeze and print the hash. --no-wait-for-",
        "# vote-to-start-leader lets it produce slot 0 immediately. A bounded",
        "# `timeout 45` caps its lifetime so it never lingers.",
        "timeout 100 agave-validator \\",
        "  --ledger /data/" + _PROBE_LEDGER_SUBDIR + " \\",
        '  --identity /data/bootstrap-identity.json \\',
        '  --vote-account "${BOOTSTRAP_VOTE}" \\',
        '  --bind-address "$MY_IP" \\',
        # NOTE: no --gossip-host here. Agave 4.3.0's agave-validator has NO
        # --gossip-host flag (only --gossip-port); --gossip-host is a Jito-fork
        # addition (jito-solana args.rs:853). The proven smoke-shared-genesis.sh
        # probe runs against the JITO image, which accepts it. This probe runs
        # against the Agave image (GENESIS_IMAGE=AGAVE_IMAGE), so it MUST omit
        # it. --gossip-host only sets the *advertised* gossip hostname anyway,
        # which is irrelevant for a standalone probe that never accepts inbound
        # gossip peers — --bind-address + --gossip-port are sufficient to bind
        # the gossip socket and reach bank-0 freeze.
        '  --public-tpu-address "${MY_IP}:8003" \\',
        '  --public-tpu-forwards-address "${MY_IP}:8004" \\',
        '  --public-tvu-address "${MY_IP}:8002" \\',
        "  --gossip-port 8001 \\",
        "  --dynamic-port-range 8002-8035 \\",
        "  --rpc-bind-address 127.0.0.1 \\",
        "  --rpc-port 9899 \\",
        "  --no-snapshots \\",
        "  --no-genesis-fetch \\",
        "  --no-snapshot-fetch \\",
        "  --no-xdp \\",
        "  --no-os-network-limits-test \\",
        "  --no-poh-speed-test \\",
        "  --no-port-check \\",
        "  --allow-private-addr \\",
        "  --no-wait-for-vote-to-start-leader \\",
        "  --limit-blockstore-size 100000000 \\",
        '  --expected-genesis-hash "$GENESIS_HASH" \\',
        '  --expected-shred-version "$SHRED_VERSION" \\',
        "  --log - > /tmp/probe.log 2>&1 &",
        'PROBE_PID=$!',
        'echo "[probe] validator pid=$PROBE_PID"',
        "",
        "# Poll up to 90s for the `bank frozen: 0 hash:` line. Under OrbStack",
        "# Rosetta/TCG the Agave validator can be slow to reach bank-0 freeze,",
        "# so the window is generous (smoke-shared-genesis.sh uses 90 iterations).",
        "BANK_HASH=\"\"",
        "for _ in $(seq 1 90); do",
        "  BANK_HASH=\"$(sed -n 's/.*bank frozen: 0 hash: \\([^ ]*\\).*/\\1/p' /tmp/probe.log 2>/dev/null | tail -n 1)\"",
        '  if [[ -n "$BANK_HASH" ]]; then break; fi',
        '  if ! kill -0 "$PROBE_PID" 2>/dev/null; then',
        '    echo "[probe] validator exited before freezing bank 0" >&2',
        "    # Dump the full log to stdout so it reaches the Kurtosis exec output",
        "    # (plan.exec captures stdout; this lets us diagnose on failure).",
        "    echo '--- probe.log (validator exited) ---'",
        "    cat /tmp/probe.log 2>/dev/null",
        "    echo '--- end probe.log ---'",
        "    exit 1",
        "  fi",
        "  sleep 1",
        "done",
        'if [[ -z "$BANK_HASH" ]]; then',
        '  echo "[probe] FATAL: could not capture slot-0 bank hash in 90s" >&2',
        "  echo '--- probe.log (timeout) ---'",
        "  cat /tmp/probe.log 2>/dev/null",
        "  echo '--- end probe.log ---'",
        "  # Still kill the validator before exiting.",
        '  kill "$PROBE_PID" 2>/dev/null || true',
        "  exit 1",
        "fi",
        'echo "BANK_HASH=$BANK_HASH"',
        'echo "[probe] captured bank-0 hash=$BANK_HASH"',
        "# Persist the hash to a FILE (not just stdout). plan.exec's returned",
        "# `output` field is truncated for long-running execs (the validator probe",
        "# streams ~90s of log; only the first ~66 bytes survive in result.output).",
        "# A second short `cat` exec below reads this file — its output is tiny and",
        "# survives intact.",
        'printf "%s" "$BANK_HASH" > /tmp/bank_hash.txt',
        "# Kill the probe validator explicitly (timeout would too, but be safe).",
        'kill "$PROBE_PID" 2>/dev/null || true',
        "wait \"$PROBE_PID\" 2>/dev/null || true",
        "exit 0",
    ]
    script = "\n".join(lines)
    return ["bash", "-c", script]


def capture_bank_hash(plan, genesis_artifact, global_node_selectors={}):
    """Boot a short-lived probe validator, return the slot-0 bank hash string.

    Args:
        plan: the Kurtosis plan
        genesis_artifact: the files-artifact name from generate_genesis (mounted
            at /data so /data/meta.env, /data/bootstrap-identity.json, and
            /data/probe-ledger/ are available)
        global_node_selectors: optional node selectors

    Returns: the slot-0 bank hash string (base58), to pass as
        --expected-bank-hash to both voting validators.
    """
    name = "bank-hash-probe"
    plan.print(
        "Launching bank-hash probe '{0}' (privileged; captures slot-0 bank hash)"
        .format(name),
    )

    config_args = {
        "image": constants.GENESIS_IMAGE,
        # sleep-infinity entrypoint so plan.exec can run the probe stages
        # (the validator is launched inside the exec, not as the container's
        # main process). Same pattern as the SIG observer launcher.
        "entrypoint": ["sleep"],
        "cmd": ["infinity"],
        "files": {constants.GENESIS_DATA_MOUNTPOINT: genesis_artifact},
        "node_selectors": global_node_selectors,
        # PRIVILEGED is REQUIRED: agave 4.3.0 fs/src/dirs.rs:12 hard-asserts
        # io_uring_supported() on Linux; OrbStack's default seccomp makes
        # io_uring_setup return EPERM in non-privileged containers. Verified:
        # plan.run_sh is NOT privileged (CapEff=0) even under `kurtosis run
        # --privileged`; only add_service(privileged=True) clears the gate.
        # REQUIRES `kurtosis run --privileged`.
        "privileged": True,
    }

    service = plan.add_service(name=name, config=ServiceConfig(**config_args))
    plan.print("Bank-hash probe container started (sleep infinity, privileged).")

    # Run the probe validator. It writes the captured slot-0 bank hash to
    # /tmp/bank_hash.txt on success, or exits non-zero (with the validator log
    # dumped to stdout) on failure.
    result = plan.exec(
        recipe=ExecRecipe(command=_probe_cmd()),
        service_name=name,
        acceptable_codes=[0],
    )
    out = result.get("output", "")

    # plan.exec's returned `output` field is TRUNCATED for long-running execs
    # (this probe streams ~90s of validator log; only the first ~66 bytes
    # survive in result.output). The streamed log shows everything, but the
    # returned struct does not. So we CANNOT parse BANK_HASH= out of `out`
    # here. Instead the probe writes the hash to /tmp/bank_hash.txt, and we
    # read it back with a SECOND short `cat` exec whose output is tiny (~44
    # bytes) and survives intact. (The SIG launcher's classify exec works
    # because its entire output is a single short line.)
    read_result = plan.exec(
        recipe=ExecRecipe(command=["bash", "-c", "cat /tmp/bank_hash.txt"]),
        service_name=name,
        acceptable_codes=[0],
    )
    bank_hash = read_result.get("output", "").strip()

    if bank_hash == "":
        # Dump whatever the probe exec returned for diagnosis, then fail. The
        # probe script dumps /tmp/probe.log to stdout on its own failure paths
        # (validator-exited-before-freeze / timeout); `out` may carry part of
        # it (truncated) plus the streamed output.
        plan.print(
            "Bank-hash probe FAILED to capture slot-0 bank hash. "
            + "Probe exec output (may be truncated):\n"
            + out,
        )
        fail(
            "Bank-hash probe did not capture a slot-0 bank hash; cannot safely "
            + "pass --wait-for-supermajority/--expected-bank-hash to the voting "
            + "validators.",
        )

    plan.print("Bank-hash probe captured slot-0 bank hash: " + bank_hash)

    # Stop and remove the probe service now that we have the hash. It must not
    # linger (it holds the bootstrap identity and could confuse gossip). We
    # tolerate non-zero exit (the probe validator is killed inside the exec;
    # the container's sleep-infinity is what we stop here).
    plan.stop_service(name=name)

    return bank_hash
