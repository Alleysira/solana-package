# firedancer-single-node.star
#
# Kurtosis package: single-node Firedancer (Frankendancer) service.
#
# HONESTY CONTRACT (see README-FIREDANCER-CONTAINER.md + AGENTS.md):
# The real-run path (real_run=True) requires a host kernel that exposes
# /sys/kernel/mm/hugepages and /sys/devices/system/node — i.e.
# CONFIG_HUGETLBFS=y + CONFIG_NUMA=y — plus root in the container. On this
# Mac Studio, OrbStack's kernel exposes NEITHER (verified by live probe:
# `ls /sys/kernel/mm/hugepages` -> No such file; `ls /sys/devices/system/node`
# -> No such file). This is a kernel-config limitation, not a privilege one:
# no amount of --privileged or sysctls can create sysfs the kernel does not
# expose. `fdctl configure init all` therefore fails at the hugetlbfs stage
# in ANY OrbStack container, Kurtosis or compose.
#
# On a host without hugepages/NUMA, this package runs the build-evidence path
# (real_run=False, the default): the container starts and runs `fdctl version`
# + `solana --version`, and we capture the output. Evidence level: `built`.
#
# On a capable host (real bare-metal x86_64 Linux with NUMA + hugepages + root,
# or a standard-kernel QEMU VM that exposes them), pass real_run=True with a
# config artifact and keys artifact to attempt `fdctl run`.

FIREDANCER_IMAGE = "solana-diff/firedancer:v26.09.4-frankendancer-amd64"

def run(plan, image = FIREDANCER_IMAGE, real_run = False, config_artifact = None, keys_artifact = None):
    """Deploy a single Firedancer (Frankendancer) service in Kurtosis.

    Args:
        plan: the Kurtosis plan
        image: container image to use
        real_run: if True, attempt `fdctl run` (requires a NUMA+hugepages host).
                  If False (default), run `version` for build-evidence only.
        config_artifact: name of a Kurtosis artifact holding config.toml (real_run only)
        keys_artifact: name of a Kurtosis artifact holding identity/vote keypairs (real_run only)
    Returns:
        the service object
    """
    if real_run:
        if not config_artifact or not keys_artifact:
            plan.fail("real_run=True requires config_artifact and keys_artifact")
        cmd = ["run"]
        files = {
            "/var/lib/firedancer/config.toml": config_artifact,
            "/var/lib/firedancer/keys": keys_artifact,
        }
    else:
        # Build-evidence path: verify the binaries exist and report versions.
        cmd = ["version"]
        files = {}

    config_args = {
        "image": image,
        "cmd": cmd,
        # Firedancer needs root for `configure init all` (hugepages/sysctls)
        # on the real-run path; we do NOT pass cap_drop:ALL because that breaks
        # configure init all (it needs CAP_SYS_ADMIN for hugetlbfs mount/unshare).
        # Kurtosis does not expose security_opt/cap_drop on ServiceConfig in
        # this version, so the container runs with the engine's default caps;
        # the real-run path relies on the host kernel exposing hugepages+NUMA.
        # NOTE: cpu_allocation/memory_allocation are omitted because OrbStack's
        # cgroup v2 rejects the cpu.max quota Kurtosis writes
        # ("failed to write 400 100000: invalid argument"). The container runs
        # unconstrained by cgroup CPU/memory limits instead.
        "files": files,
        "ports": {"rpc": PortSpec(number = 8899, transport_protocol = "TCP")},
    }

    service = plan.add_service(name = "firedancer", config = ServiceConfig(**config_args))

    # Readiness: the version path exits 0 quickly. For a real run, the
    # embedded Agave takes minutes to boot; a short wait would time out, so
    # real-run readiness is left to the caller. Use ExecRecipe so we don't
    # depend on Firedancer's (unimplemented) HTTP RPC for a health GET.
    if not real_run:
        plan.wait(
            service_name = "firedancer",
            recipe = ExecRecipe(command = ["bash", "-c", "command -v fdctl >/dev/null && fdctl version >/dev/null 2>&1"]),
            field = "code",
            assertion = "==",
            target_value = "0",
            timeout = "60s",
        )
        plan.print(
            "Firedancer deployed in BUILD-EVIDENCE mode (version check only). " +
            "On this host (OrbStack, no NUMA sysfs/hugepages) the validator " +
            "CANNOT start: `fdctl configure init all` fails at the hugetlbfs " +
            "stage. Evidence level: built."
        )

    return service
