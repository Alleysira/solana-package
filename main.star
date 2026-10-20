# Multi-client Solana Kurtosis package — entry point.
#
# Runs a shared-genesis testnet with two voting validators (Jito bootstrap +
# Agave joiner) plus one SIG non-voting observer in a single Kurtosis enclave,
# waits for the network to produce `slots_target` slots (default 20), captures
# machine-readable evidence, and returns. SIG is a NON-VOTING observer; the
# slots come from the two voting validators. This is NEVER a three-voting-
# validator claim.

input_parser = import_module("./src/package_io/input_parser.star")
participant_network = import_module("./src/participant_network.star")
slot_verifier = import_module("./src/verification/slot_verifier.star")


def run(plan, args={}):
    """Launch the multi-client shared-genesis testnet and wait for N slots.

    Args:
        args: A YAML or JSON argument to configure the network. Schema:
            slots_target: int (default 20)
            participants: {bootstrap_image: ..., joiner_image: ...}
            genesis: {cluster_type, hashes_per_tick, ticks_per_slot, ...}
            sig: {image, enabled, skip_on_cold_start, run_timeout_seconds}
            explorer: {enabled: false}
    """
    # Parse input parameters.
    parsed = input_parser.input_parser(plan, args)

    global_node_selectors = {}

    # Launch the participant network: genesis → bootstrap → joiner → SIG.
    topology = participant_network.launch_participant_network(
        plan,
        parsed,
        global_node_selectors,
    )

    plan.print("Multi-client shared-genesis network launched.")
    plan.print("  Bootstrap (voting): {0}".format(topology.bootstrap.rpc_url))
    plan.print("  Joiner  (voting): {0}".format(topology.joiner.rpc_url))
    plan.print(
        "  SIG     (NON-VOTING observer, evidence={0})".format(topology.sig.evidence_level),
    )

    # Wait for both voting validators to be non-delinquent and for the slot
    # count to reach slots_target, then capture the evidence JSON. This is the
    # 20-slot goal gate. SIG's evidence level is recorded, NOT required.
    verification = slot_verifier.wait_for_slots(
        plan,
        topology,
        parsed.slots_target,
        global_node_selectors,
    )

    plan.print("Slot target {0} reached; evidence captured.".format(parsed.slots_target))

    return struct(
        bootstrap_rpc_url=topology.bootstrap.rpc_url,
        joiner_rpc_url=topology.joiner.rpc_url,
        sig_evidence_level=topology.sig.evidence_level,
        slot_reached=verification.slot_reached,
        evidence_json=verification.evidence_json,
    )
