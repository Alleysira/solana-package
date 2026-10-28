"""Kurtosis network: Jito, Agave and full Firedancer voters plus SIG observer."""
input_parser = import_module("./src/package_io/input_parser.star")
participant_network = import_module("./src/participant_network.star")
slot_verifier = import_module("./src/verification/slot_verifier.star")

def run(plan, args={}):
    parsed = input_parser.input_parser(plan, args)
    topology = participant_network.launch_participant_network(plan, parsed)
    verification = slot_verifier.wait_for_slots(
        plan, topology, parsed.slots_target,
        observation_seconds=parsed.verification_config["observation_seconds"],
    )
    return struct(
        bootstrap_rpc_url=topology.bootstrap.rpc_url,
        joiner_rpc_url=topology.joiner.rpc_url,
        firedancer_rpc_url="http://val-firedancer:8899",
        sig_evidence_level="joined",
        slot_reached=verification.slot_reached,
        evidence_json=verification.evidence_json,
        evidence_artifact=verification.evidence_artifact,
    )
