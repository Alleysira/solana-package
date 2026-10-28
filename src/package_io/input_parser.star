# Multi-client Solana Kurtosis package — input parser.
#
# Schema (mirrors ethereum-package's input_parser):
#   participants  : list of {el_client, cl_client, ...} — NOT used; Solana
#                   collapses EL/CL into a single validator role, so we use
#                   explicit image overrides instead.
#   slots_target  : int  — wait until slot >= this, then return (default 20)
#   genesis       : dict — genesis knobs (faucet/stake lamports, slots/epoch)
#   sig           : dict — SIG observer config (image, skip_on_cold_start)
#   explorer      : dict — {enabled: bool} (default False)

constants = import_module("./constants.star")

DEFAULT_SLOTS_TARGET = 20


def input_parser(plan, args):
    plan.print("Parsing multi-client input parameters")

    if args == None:
        args = {}

    # ── slots_target ──────────────────────────────────────────────────────
    slots_target = args.get("slots_target", DEFAULT_SLOTS_TARGET)
    if type(slots_target) == "string":
        slots_target = int(slots_target)
    if slots_target < 1:
        fail("slots_target must be a positive integer, got {0}".format(slots_target))

    # ── participants (image overrides) ────────────────────────────────────
    # Each validator role defaults to its verified image; callers may override
    # by image tag for experimentation. We do NOT allow swapping a role to a
    # renamed test-validator / dev library — the role semantics are fixed.
    participants = args.get("participants", {})
    bootstrap_image = participants.get("bootstrap_image", constants.JITO_IMAGE)
    joiner_image = participants.get("joiner_image", constants.AGAVE_IMAGE)
    firedancer_image = participants.get("firedancer_image", constants.FIREDANCER_IMAGE)

    # ── genesis knobs (all optional, default to constants) ─────────────────
    genesis = args.get("genesis", {})
    genesis_config = {
        "cluster_type": genesis.get("cluster_type", constants.CLUSTER_TYPE),
        "hashes_per_tick": genesis.get("hashes_per_tick", constants.HASHES_PER_TICK),
        "ticks_per_slot": genesis.get("ticks_per_slot", constants.TICKS_PER_SLOT),
        "slots_per_epoch": genesis.get("slots_per_epoch", constants.SLOTS_PER_EPOCH),
        "faucet_lamports": genesis.get("faucet_lamports", constants.FAUCET_LAMPORTS),
        "bootstrap_validator_lamports": genesis.get(
            "bootstrap_validator_lamports", constants.BOOTSTRAP_VALIDATOR_LAMPORTS
        ),
        "bootstrap_validator_stake_lamports": genesis.get(
            "bootstrap_validator_stake_lamports", constants.BOOTSTRAP_STAKE_LAMPORTS
        ),
        "firedancer_stake_lamports": genesis.get(
            "firedancer_stake_lamports", constants.FIREDANCER_STAKE_LAMPORTS
        ),
    }

    # ── SIG observer config ───────────────────────────────────────────────
    sig = args.get("sig", {})
    sig_config = {
        "image": sig.get("image", constants.SIG_IMAGE),
        "enabled": sig.get("enabled", True),
        # Functional path (default): SIG downloads a REAL snapshot from the
        # bootstrap via HTTP + receives a real shred stream. The cold-start
        # bypass (true) is a fallback for slot-0 clusters with no snapshot.
        "skip_on_cold_start": sig.get("skip_on_cold_start", False),
        "run_timeout_seconds": sig.get("run_timeout_seconds", 60),
    }

    verification = args.get("verification", {})
    observation_seconds = verification.get("observation_seconds", 600)
    if type(observation_seconds) == "string":
        observation_seconds = int(observation_seconds)
    if type(observation_seconds) != "int" or observation_seconds < 60:
        fail("verification.observation_seconds must be an integer >= 60")
    if not sig_config["enabled"] or sig_config["skip_on_cold_start"]:
        fail("The four-client acceptance requires SIG enabled with a real snapshot")
    verification_config = {
        "observation_seconds": observation_seconds,
        "image": verification.get("image", constants.VERIFIER_IMAGE),
    }

    # ── explorer (off by default — not needed for the 20-slot goal) ────────
    explorer = args.get("explorer", {})
    explorer_config = {
        "enabled": explorer.get("enabled", False),
    }

    return struct(
        verification_config = verification_config,
        slots_target = slots_target,
        bootstrap_image = bootstrap_image,
        joiner_image = joiner_image,
        firedancer_image = firedancer_image,
        genesis_config = genesis_config,
        sig_config = sig_config,
        explorer_config = explorer_config,
    )
