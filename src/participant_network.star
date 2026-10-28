# Participant network — orchestrates the multi-client shared-genesis testnet.
#
# Mirrors ethereum-package's participant_network module: generate ONE genesis
# artifact, then launch each participant against it. Solana collapses EL/CL into
# a single validator role per client, so the participants are:
#   - bootstrap validator (Jito, voting)
#   - joiner  validator (Agave, voting)  ← first mixed-client Jito+Agave run
#   - SIG observer (non-voting, development cluster, functional path)
#
# The two voting validators produce the 20 slots (the goal). SIG is a non-voting
# observer — structurally impossible to vote (no vote/stake accounts, no vote
# config field). It starts and (best case) joins the gossip/shred stream as a
# third, independently-implemented client, following the OFFICIAL "Running a
# functional Sig validator" path (README §steps 1-4):
#   1. extract the real leader schedule from the bootstrap RPC.
#   2. mount it as SIG's leader_schedule_file.
#   3. start `sig config.zon` (skip_on_cold_start=false → real snapshot download).
#   4. run `shred-stream` inside the bootstrap, targeting SIG's IP:8002.
# This is NEVER a three-voting-validator claim.
#
# ─────────────────────────────────────────────────────────────────────────────
# ORDERING (why the shred-stream artifact is built FIRST)
# ─────────────────────────────────────────────────────────────────────────────
# The bootstrap validator's ServiceConfig(files=) is set at add_service time —
# you cannot attach a files-artifact to an already-running service. The
# shred-stream binary must be mounted on the bootstrap (it runs inside the
# bootstrap against the bootstrap's live blockstore at
# /data/bootstrap-ledger/rocksdb). Therefore the shred-stream files-artifact
# MUST be built BEFORE the bootstrap service is launched. build_shred_stream_artifact
# has NO running-service dependency (it only copies the prebuilt binary out of
# the SIG image), so it can run first.

genesis_launcher = import_module("./genesis/genesis_launcher.star")
bank_hash_probe = import_module("./genesis/bank_hash_probe.star")
solana_validator = import_module("./solana_validator/solana_validator_launcher.star")
firedancer_validator = import_module("./firedancer/firedancer_launcher.star")
sig_observer = import_module("./sig_observer/sig_observer_launcher.star")
constants = import_module("./package_io/constants.star")

# ── shred-stream window (the SIG replay OutOfSpace fix) ─────────────────────
# SIG's replay merkle forest is a FIXED 4096-node pool (replay.zig:1482) with
# NO root reclamation. A slot carries ~33 FEC sets (last idx=32), so the pool
# holds only ~124 slots of live data. We feed a contiguous window starting at
# SIG's snapshot slot; 64 slots (≈2112 nodes) leaves ample headroom below the
# 4096 cap while giving SIG a substantial contiguous span to replay. This is
# the bounded window that replaces the prior unbounded `--start-slot 0`.
_SHRED_STREAM_WINDOW_SLOTS = 64


def launch_participant_network(plan, args, global_node_selectors={}):
    """Generate genesis and launch bootstrap + joiner + SIG observer.

    Args:
        plan: the Kurtosis plan
        args: the parsed input struct from input_parser (bootstrap_image,
            joiner_image, genesis_config, sig_config, explorer_config)
        global_node_selectors: optional node selectors

    Returns: struct(bootstrap, joiner, sig, bank_hash)
        bootstrap: struct(service, name, rpc_url, identity_pubkey_var, vote_pubkey_var)
        joiner:    struct(service, name, rpc_url, identity_pubkey_var, vote_pubkey_var)
        sig:       struct(service, name, evidence_level, log_path)
    """
    plan.print("Launching multi-client shared-genesis participant network")

    # Stage 0: build the shred-stream files-artifact FIRST (before the bootstrap
    # service is launched). The bootstrap must mount this artifact at
    # /opt/shred-stream so shred-stream can run inside the bootstrap container
    # against its live blockstore. This has no running-service dependency, so it
    # can run before the network exists. (Official functional path step 4 prep.)
    shred_stream_artifact = sig_observer.build_shred_stream_artifact(
        plan,
        sig_image=args.sig_config["image"],
        global_node_selectors=global_node_selectors,
    )
    plan.print("Built shred-stream files-artifact: {0}".format(shred_stream_artifact))

    # Stage 1: generate the shared genesis artifact ONCE. Every participant mounts
    # it at /data. The artifact carries the genesis ledger, per-node ledger copies,
    # all keypairs, and a shell-sourceable /data/meta.env.
    genesis_artifact = genesis_launcher.generate_genesis(plan, args.genesis_config)

    # Stage 2: capture the slot-0 bank hash. This is the cold-start coordination
    # value: both validators pass --wait-for-supermajority 0 --expected-bank-hash
    # <hash> so they wait until 80% of stake is visible in gossip before starting
    # PoH (core/src/validator.rs:3062). Without it, the bootstrap (with
    # --no-wait-for-vote-to-start-leader) outruns the joiner, they never overlap,
    # and 50/50 stake can't reach the 2/3 finalization threshold → voting
    # standstill (LockedOut(255)/FailedThreshold(255) + in_standstill_bool=true).
    # The probe is a SEPARATE privileged service because plan.run_sh containers
    # are NOT privileged even under `kurtosis run --privileged` (agave 4.3.0
    # fs/src/dirs.rs:12 hard-asserts io_uring_supported(); OrbStack EPERMs it).
    bank_hash = bank_hash_probe.capture_bank_hash(
        plan,
        genesis_artifact,
        global_node_selectors,
    )

    # Stage 3: launch the bootstrap voting validator (Jito by default). It starts
    # first with --no-wait-for-vote-to-start-leader and --wait-for-supermajority 0.
    # The shred-stream artifact is mounted at /opt/shred-stream via extra_files,
    # so shred-stream can run inside this container later (stage 7).
    bootstrap = solana_validator.launch_validator(
        plan,
        role=constants.ROLE_VOTING_BOOTSTRAP,
        image=args.bootstrap_image,
        genesis_artifact=genesis_artifact,
        bank_hash=bank_hash,
        global_node_selectors=global_node_selectors,
        extra_files={
            sig_observer._SHRED_STREAM_BIN_PATH: shred_stream_artifact,
        },
    )

    # Stage 4: launch the joiner voting validator (Agave by default). It joins
    # via --entrypoint <bootstrap>:8001 and --wait-for-supermajority 0. This is
    # the first mixed-client (Jito + Agave) shared-genesis voting pair.
    joiner = solana_validator.launch_validator(
        plan,
        role=constants.ROLE_VOTING_JOINER,
        image=args.joiner_image,
        genesis_artifact=genesis_artifact,
        bank_hash=bank_hash,
        global_node_selectors=global_node_selectors,
    )

    firedancer = firedancer_validator.launch_firedancer(
        plan,
        genesis_artifact=genesis_artifact,
        image=args.firedancer_image,
    )

    # Stage 5: extract the REAL leader schedule from the bootstrap RPC (official
    # functional path step 1-2). This MUST run after the bootstrap + joiner are
    # launched and producing slots, so the schedule reflects the real stake
    # distribution (both validators' stake). `solana leader-schedule` is a
    # read-only RPC call (no ledger touch → no io_uring assert), so it can run in
    # an unprivileged plan.run_sh reaching http://val-bootstrap:8899 over
    # in-enclave DNS. The genesis image (Agave) has the `solana` CLI.
    schedule_artifact = sig_observer.build_schedule_artifact(
        plan,
        schedule_image=constants.GENESIS_IMAGE,
        global_node_selectors=global_node_selectors,
    )
    plan.print("Built leader-schedule files-artifact: {0}".format(schedule_artifact))

    # Stage 6: launch the SIG non-voting observer (development cluster, functional
    # path). It mounts the genesis artifact (for /data/meta.env: SHRED_VERSION) and
    # the real leader-schedule artifact (at /var/lib/sig/schedule, exposing
    # /var/lib/sig/schedule/schedule.txt), sets
    # skip_on_cold_start=false (real snapshot download from the bootstrap), and
    # joins the bootstrap's gossip endpoint as an observer. evidence_level is the
    # honest lowest-proven ("started" | "joined" | "not_started"); NEVER "voting".
    sig = sig_observer.launch_sig_observer(
        plan,
        sig_config=args.sig_config,
        genesis_artifact=genesis_artifact,
        schedule_artifact=schedule_artifact,
        global_node_selectors=global_node_selectors,
    )

    # Stage 7: run shred-stream INSIDE the bootstrap container, targeting SIG's
    # resolved IP:8002 (official functional path step 4). This feeds SIG a
    # CONTIGUOUS, BOUNDED window of shreds starting at SIG's snapshot slot (SIG
    # has no repair, so it needs a complete external shred stream).
    #
    # WHY A BOUNDED WINDOW (the OutOfSpace fix): SIG's replay merkle forest is a
    # FIXED 4096-node pool (replay.zig:1482) with NO root reclamation. A slot is
    # ~33 FEC sets, so only ~124 slots fit. The prior run passed --start-slot 0
    # (the whole blockstore, ~14965 slots) → pool overflow → error.OutOfSpace at
    # pool.zig:280, killing replay. The official doc says to feed "all slots
    # starting at the snapshot slot being used by sig", so we:
    #   1. read SIG's ACTUAL snapshot slot from its log (it may be far behind the
    #      live cluster tip — the cluster races ahead fast under hashes-per-tick
    #      = sleep), then
    #   2. stream a contiguous window [snapshot_slot, snapshot_slot + WINDOW]
    #      that fits the pool.
    # shred-stream is mounted on the bootstrap at /opt/shred-stream (stage 3's
    # extra_files); it reads the bootstrap's live blockstore at
    # /data/bootstrap-ledger/rocksdb. --target uses a literal IP (parseIpAndPort
    # rejects hostnames), so the script resolves sig-observer → IP via getent.
    # This is the last stage before the slot verifier — it is NOT a gate for the
    # 20-slot goal (the two voting validators produce the slots); it is the
    # functional-path step that gives SIG real shreds to process.
    sig_snapshot_slot = sig_observer.read_snapshot_slot(
        plan,
        service_name=sig.name,
    )
    # NOTE: sig_snapshot_slot is a Kurtosis RUNTIME VALUE (not a Python int) — we
    # cannot print or do arithmetic on it in Starlark. It is passed straight into
    # _run_shred_stream_cmd, which concatenates it into the shell script (it
    # expands to the number at runtime) and computes the window end in shell.
    plan.print(
        "Running shred-stream on bootstrap → sig over window "
        + "(snapshot slot)..(snapshot slot + {0})".format(_SHRED_STREAM_WINDOW_SLOTS),
    )
    plan.exec(
        recipe=ExecRecipe(
            command=sig_observer._run_shred_stream_cmd(
                sig_snapshot_slot, _SHRED_STREAM_WINDOW_SLOTS,
            ),
        ),
        service_name=bootstrap.name,
        acceptable_codes=[0, 1],
    )

    # Stage 8: let SIG ingest the streamed shreds, then classify its evidence
    # level. SIG replays the window asynchronously (shred_receiver → replay), so
    # we give it a bounded settle window before reading the log markers. The
    # classification MUST happen here (after shred-stream), not inside
    # launch_sig_observer — otherwise SIG has received no shreds yet and always
    # reports not_started (a false negative).
    plan.exec(
        recipe=ExecRecipe(command=["bash", "-c", "sleep 20"]),
        service_name=sig.name,
        acceptable_codes=[0],
    )
    sig_evidence_level = sig_observer.classify_sig_evidence(plan, sig.name)

    plan.print(
        ("Participant network launched: bootstrap={0} (Jito, voting), "
         + "joiner={1} (Agave, voting), sig={2} (NON-VOTING observer, evidence={3}), "
         + "shred-stream ran inside bootstrap → sig over a bounded window from SIG's snapshot slot")
        .format(bootstrap.name, joiner.name, sig.name, sig_evidence_level),
    )

    # bank_hash is threaded into the topology so the slot_verifier can include it
    # in the evidence JSON. It is NOT in meta.env (the genesis artifact is baked
    # before the bank hash exists); the validators receive it as a baked literal
    # in their cmd, and the verifier gets it via the topology struct. sig carries
    # the post-shred-stream evidence level so the verifier records the honest
    # value (the provisional level from launch_sig_observer is superseded).
    return struct(
        bootstrap=bootstrap,
        joiner=joiner,
        firedancer=firedancer,
        sig=struct(
            service=sig.service,
            name=sig.name,
            evidence_level=sig_evidence_level,
            log_path=sig.log_path,
        ),
        bank_hash=bank_hash,
    )
