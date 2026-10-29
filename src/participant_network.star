"""Shared genesis: three voting validators and one SIG observer."""
genesis_launcher = import_module("./genesis/genesis_launcher.star")
bank_hash_probe = import_module("./genesis/bank_hash_probe.star")
solana_validator = import_module("./solana_validator/solana_validator_launcher.star")
firedancer_validator = import_module("./firedancer/firedancer_launcher.star")
sig_observer = import_module("./sig_observer/sig_observer_launcher.star")
verification = import_module("./verification/slot_verifier.star")
constants = import_module("./package_io/constants.star")

def launch_participant_network(plan, args, global_node_selectors={}):
    # SIG v2 only implements Tower BFT; it has no votor/BLS path, so it cannot
    # follow an Alpenglow cluster. Skip it entirely when Alpenglow is enabled
    # rather than launching an observer that would silently fall behind.
    with_sig = not args.genesis_config.get("alpenglow", False)
    shred_artifact = (
        sig_observer.build_shred_stream_artifact(plan, args.sig_config["image"])
        if with_sig else None
    )
    genesis_artifact = genesis_launcher.generate_genesis(plan, args.genesis_config)
    bank_hash = bank_hash_probe.capture_bank_hash(plan, genesis_artifact, global_node_selectors)
    bootstrap = solana_validator.launch_validator(
        plan, constants.ROLE_VOTING_BOOTSTRAP, args.bootstrap_image,
        genesis_artifact, bank_hash, global_node_selectors,
        extra_files={sig_observer._SHRED_STREAM_BIN_PATH: shred_artifact} if with_sig else {},
    )
    joiner = solana_validator.launch_validator(
        plan, constants.ROLE_VOTING_JOINER, args.joiner_image,
        genesis_artifact, bank_hash, global_node_selectors,
    )
    firedancer = firedancer_validator.launch_firedancer(
        plan, genesis_artifact=genesis_artifact, image=args.firedancer_image,
        alpenglow=args.genesis_config.get("alpenglow", False),
    )
    verifier = verification.launch_verifier(plan, genesis_artifact, args.verification_config["image"])
    sig = None
    if with_sig:
        snapshot_artifact = verification.prepare_sig_snapshot(plan, verifier)
        schedule_artifact = sig_observer.build_schedule_artifact(plan, constants.GENESIS_IMAGE)
        sig = sig_observer.launch_sig_observer(
            plan, args.sig_config, genesis_artifact, schedule_artifact,
            global_node_selectors, initial_snapshot_artifact=snapshot_artifact,
        )
        snapshot_slot = sig_observer.read_snapshot_slot(plan, sig.name)
        plan.exec(
            service_name=bootstrap.name,
            recipe=ExecRecipe(command=sig_observer._run_shred_stream_cmd(snapshot_slot, 64)),
            acceptable_codes=[0],
        )
    # SIG has no continuous-replay implementation at this pin; network
    # acceptance requires live peer membership. Under Alpenglow SIG is not
    # launched at all (see with_sig above).
    return struct(
        bootstrap=bootstrap, joiner=joiner, firedancer=firedancer, sig=sig,
        verifier=verifier, bank_hash=bank_hash,
    )
