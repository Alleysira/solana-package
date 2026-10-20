# firedancer-realrun-probe.star
#
# Kurtosis package: probe the real `fdctl run` path in a Kurtosis container on
# THIS host (OrbStack), to capture honest machine-readable evidence of exactly
# where the validator hits the kernel gate.
#
# EXPECTED OUTCOME (per README-FIREDANCER-CONTAINER.md and prior live probes):
# OrbStack's kernel exposes NO /sys/kernel/mm/hugepages and NO
# /sys/devices/system/node (verified). `fdctl configure init all` therefore
# fails at the hugetlbfs stage. This probe confirms that inside a real
# Kurtosis container (not compose, not QEMU) and records the exact error.
#
# The container is started with an `sleep infinity` entrypoint so it stays
# alive for plan.exec; then each stage is run and its exit code + output
# captured separately. This is NOT a "started" claim — it is a captured
# BLOCKED result proving the kernel gate fires under Kurtosis exactly as it
# does under compose.

FIREDANCER_IMAGE = "solana-diff/firedancer:v26.09.4-frankendancer-amd64"

def _run_capture(plan, name, command, accept_codes = [0]):
    """Run a command in the firedancer container via plan.exec and print a
    labelled capture of its exit code + stderr/stdout. accept_codes lets us
    capture a non-zero exit (e.g. the expected hugetlbfs gate failure)."""
    result = plan.exec(
        recipe = ExecRecipe(command = command),
        service_name = "firedancer",
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

def run(plan, image = FIREDANCER_IMAGE):
    """Deploy the firedancer container (kept alive) and probe the run path."""
    config_args = {
        "image": image,
        "entrypoint": ["sleep"],
        "cmd": ["infinity"],
        # No ports declared: nothing listens in probe mode. Avoids Kurtosis's
        # port-readiness timeout that fires when a probed service doesn't bind.
    }
    plan.add_service(name = "firedancer", config = ServiceConfig(**config_args))

    plan.print("Firedancer container started (probe mode, sleep infinity).")

    # Stage 1: confirm the OrbStack kernel gate — do hugepages/NUMA sysfs exist?
    _run_capture(plan, "kernel-gate-hugepages", [
        "bash", "-c",
        "echo '--- /sys/kernel/mm/hugepages ---'; " +
        "ls /sys/kernel/mm/hugepages 2>&1; " +
        "echo '--- /proc/sys/vm/nr_hugepages ---'; " +
        "cat /proc/sys/vm/nr_hugepages 2>&1; " +
        "echo '--- /sys/devices/system/node ---'; " +
        "ls /sys/devices/system/node 2>&1; " +
        "echo '--- CONFIG probes ---'; " +
        "zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_HUGETLBFS|CONFIG_NUMA' 2>&1 || echo '(no /proc/config.gz)'",
    ])

    # Stage 2: fdctl version — confirm the binary is usable (build evidence).
    _run_capture(plan, "fdctl-version", ["bash", "-c", "fdctl version 2>&1; echo '---'; solana --version 2>&1"])

    # Stage 2b: write a minimal config with [user] so fdctl's config parser
    # (fd_config.c(300)) doesn't reject us before we reach the hugetlbfs gate.
    # The firedancer user (uid 1000) exists in the image. The actual gate
    # (hugetlbfs) is a kernel-config issue, NOT a config issue, so we still
    # expect configure init all to fail there — but we want to reach it.
    _run_capture(plan, "write-config", ["bash", "-c", "mkdir -p /var/lib/firedancer && cat > /var/lib/firedancer/config.toml <<'FDCONF'\nname = \"fdvm\"\nuser = \"firedancer\"\nscratch_directory = \"/var/lib/firedancer/fdvm\"\n\n[layout]\naffinity = \"auto\"\nagave_affinity = \"auto\"\nnet_tile_count = 1\nquic_tile_count = 1\nresolh_tile_count = 1\nverify_tile_count = 1\nbank_tile_count = 1\nshred_tile_count = 1\n\n[tiles.gui]\nenabled = false\n\n[net]\nprovider = \"socket\"\ninterface = \"eth0\"\n\n[hugetlbfs]\nmount_path = \"/mnt/.fd\"\n\n[consensus]\nsnapshot_fetch = false\ngenesis_fetch = false\npoh_speed_test = false\n\n[rpc]\nonly_known = false\n\n[development]\nbootstrap = true\nsandbox = false\n\n[development.gossip]\nallow_private_address = true\n\n[development.genesis]\nhashes_per_tick = 1\nFDCONF\n"])

    # Stage 3: attempt configure init all with the config — EXPECTED to fail
    # at the hugetlbfs stage because OrbStack's kernel exposes no hugepages/NUMA.
    # accept [0,1] so we capture the full gate failure rather than aborting.
    _run_capture(plan, "configure-init-all", ["bash", "-c", "fdctl configure init all --config /var/lib/firedancer/config.toml 2>&1"], accept_codes = [0, 1])

    # Stage 4: attempt fdctl run — EXPECTED to fail at the same gate (or earlier).
    _run_capture(plan, "fdctl-run", ["bash", "-c", "timeout 120 fdctl run --config /var/lib/firedancer/config.toml 2>&1"], accept_codes = [0, 1, 124])

    plan.print(
        "Probe complete. If configure-init-all failed at hugetlbfs (no " +
        "/sys/kernel/mm/hugepages), this is the OrbStack kernel gate — a " +
        "kernel-config limitation (CONFIG_HUGETLBFS/CONFIG_NUMA not built), " +
        "NOT a privilege issue. The validator cannot start on this host."
    )
