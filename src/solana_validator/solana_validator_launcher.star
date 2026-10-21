# Solana validator launcher — multi-client shared-genesis voting validator.
#
# Replaces the old single-node `solana-test-validator` scaffold. Each validator
# mounts the shared genesis artifact at /data (produced by genesis_launcher),
# sources /data/meta.env to pick up GENESIS_HASH / SHRED_VERSION / the per-node
# identity+vote pubkeys, and execs `agave-validator` with the shared-genesis
# argument set ported from smoke-shared-genesis.sh:102-201.
#
# Two roles:
#   - voting-bootstrap (starts first, --no-wait-for-vote-to-start-leader)
#   - voting-joiner    (starts second, --entrypoint <bootstrap>:8001)
#
# `--wait-for-supermajority 0` + `--expected-bank-hash $BANK_HASH` ARE passed
# (matching the proven smoke-shared-genesis.sh:181-182,199-200). clap marks
# `--wait-for-supermajority` .requires("expected_bank_hash")
# (jito-solana/validator/src/commands/run/args.rs:597), and both are present.
# The slot-0 bank hash is captured by a SEPARATE privileged probe service
# (bank_hash_probe.star) — it can't run inside genesis_launcher's run_sh because
# plan.run_sh containers are NOT privileged even under `kurtosis run --privileged`
# (agave fs/src/dirs.rs:12 hard-asserts io_uring_supported(); OrbStack's default
# seccomp returns EPERM). The probe returns the hash as a Starlark string;
# participant_network interpolates it into launch_validator, which bakes it into
# this cmd as a literal (NOT sourced from meta.env, which the genesis artifact
# bakes before the bank hash exists).
#
# Why this flag matters: with 50/50 stake, each validator sees only 50% alone.
# Without --wait-for-supermajority 0, the bootstrap (with
# --no-wait-for-vote-to-start-leader) barreled ahead before the joiner bound its
# sockets — they never overlapped in gossip, neither received the other's shreds
# (num_shreds_received=0), and 50/50 stake never reached the 2/3 finalization
# threshold → LockedOut(255)/FailedThreshold(255) + in_standstill_bool=true.
# --wait-for-supermajority 0 makes each validator wait until 80% of activated
# stake is visible in gossip (core/src/validator.rs:3062,
# WAIT_FOR_SUPERMAJORITY_THRESHOLD_PERCENT=80) before proceeding past slot 0, so
# both validators overlap in gossip and converge. This is the cold-start
# coordination the proven smoke harness relies on.
#
# Both images expose `agave-validator` on PATH and use `tini -g --` as the
# entrypoint (Jito image's native entrypoint; Agave image's custom
# agave-entrypoint — which starts a Node API server — is OVERRIDDEN to
# `tini -g --` here, because the multi-client run uses the validator only).
# The validator cmd is a `bash -c` wrapper so we can resolve the in-enclave IP
# at runtime (Starlark can't see the future-allocated IP) and feed it to gossip.

shared_utils = import_module("../shared_utils/shared_utils.star")
constants = import_module("../package_io/constants.star")

# The per-node ledger subdir under /data (genesis_launcher copies the genesis
# ledger into these so each validator starts from an untouched copy).
_LEDGER_SUBDIR = {
    constants.ROLE_VOTING_BOOTSTRAP: "bootstrap-ledger",
    constants.ROLE_VOTING_JOINER: "joiner-ledger",
}
_IDENTITY_KEY = {
    constants.ROLE_VOTING_BOOTSTRAP: "BOOTSTRAP_IDENTITY",
    constants.ROLE_VOTING_JOINER: "JOINER_IDENTITY",
}
_VOTE_KEY = {
    constants.ROLE_VOTING_BOOTSTRAP: "BOOTSTRAP_VOTE",
    constants.ROLE_VOTING_JOINER: "JOINER_VOTE",
}
_SERVICE_NAME = {
    constants.ROLE_VOTING_BOOTSTRAP: "val-bootstrap",
    constants.ROLE_VOTING_JOINER: "val-joiner",
}


def _validator_cmd(role, image, bank_hash):
    """Build the bash -c wrapper that execs agave-validator for the given role.

    Resolves the container's own in-enclave IP via `hostname -I` and (for the
    joiner) the bootstrap's IP via the Kurtosis DNS name `val-bootstrap`.
    Sources /data/meta.env for genesis_hash/shred_version/identity/vote/tip
    pubkeys. bank_hash is the slot-0 bank hash captured by bank_hash_probe;
    it is interpolated as a literal (NOT sourced from meta.env, which the
    genesis artifact bakes before the bank hash exists) and passed to
    --expected-bank-hash alongside --wait-for-supermajority 0.
    """
    ledger_subdir = _LEDGER_SUBDIR[role]
    identity_key = _IDENTITY_KEY[role]
    vote_key = _VOTE_KEY[role]

    # Jito-specific MEV tip args. Jito 4.3.0 PANICS at
    # validator/src/commands/run/execute.rs:1679
    # ("--tip-payment-program-pubkey argument required when validator is voting")
    # when voting without --tip-payment-program-pubkey (and the other tip args
    # that TipManagerConfig demands). Agave 4.3.0 does NOT have these args at all
    # (grep of agave/validator/ for tip_payment/merkle/commission/block_engine/
    # relayer returns nothing) — passing them to Agave's clap would be rejected
    # as unknown args. So we emit them ONLY for the Jito image. The genesis_launcher
    # already bakes TIP_PAYMENT / TIP_DISTRIBUTION / MERKLE_AUTHORITY into meta.env
    # (they are real accounts created during genesis), so they are available here.
    is_jito = "jito" in image.lower()
    if is_jito:
        # NOTE: Starlark does NOT support Python's implicit adjacent-string
        # concatenation ("a" "b"); a parenthesised sequence of bare string
        # literals is a parse error ("got string literal, want ')'"). Build the
        # block from a list joined by "" (the sig_observer_launcher uses the
        # same pattern). Each line ends with " \\\n" so it survives the
        # multi-line `exec agave-validator \` continuation in the template.
        tip_lines = [
            "  --block-engine-url '' \\\n",
            "  --relayer-url '' \\\n",
            '  --tip-payment-program-pubkey "$TIP_PAYMENT" \\\n',
            '  --tip-distribution-program-pubkey "$TIP_DISTRIBUTION" \\\n',
            '  --merkle-root-upload-authority "$MERKLE_AUTHORITY" \\\n',
            "  --commission-bps 0 \\\n",
        ]
        tip_args = "".join(tip_lines)
    else:
        tip_args = ""

    # Snapshot args are ROLE-conditional, because the SIG observer boots its
    # accounts_db from a bootstrap snapshot (the official "functional validator"
    # path: SIG has no repair, so it needs a real snapshot + a real shred stream
    # to build state). The bootstrap validator must therefore PRODUCE + ADVERTISE
    # snapshots so SIG's native HTTP downloader (snapshot.zig normal path,
    # skip_on_cold_start=false) can fetch one.
    #
    # Agave serves snapshot archives over HTTP at the RPC port
    # (rpc_service.rs:186 is_file_get_path → process_file_get) ONLY when
    # snapshot_config is Some — i.e. snapshots are ENABLED (NOT --no-snapshots;
    # --no-snapshots sets snapshot_config=None and the HTTP route 404s). And it
    # advertises snapshot hashes in gossip (CrdsValue::SnapshotHashes), which
    # SIG's gossip service picks up into SnapshotSource{rpc_addr=bootstrap RPC}.
    #
    # SIG is a COLD-START observer: no prior base state. An incremental snapshot
    # is a delta from a base full snapshot and is useless to SIG. So the
    # bootstrap uses --no-incremental-snapshots, which makes
    # --snapshot-interval-slots control the FULL snapshot interval
    # (run/execute.rs:1244-1246) — a complete, self-contained full snapshot
    # every 5 slots. Default full interval is 100000 slots (way beyond the
    # 20-slot window), so the small interval is REQUIRED for SIG to get a
    # snapshot within the observation window. --no-snapshot-fetch stays (the
    # bootstrap starts from genesis, it must not fetch a snapshot for itself).
    #
    # The joiner keeps --no-snapshots (it starts from genesis and does not need
    # to serve snapshots; only the bootstrap feeds SIG).
    if role == constants.ROLE_VOTING_BOOTSTRAP:
        snapshot_args = (
            "  --no-incremental-snapshots \\\n"
            + "  --snapshot-interval-slots 5 \\\n"
        )
    else:
        snapshot_args = "  --no-snapshots \\\n"

    # The joiner needs --entrypoint <bootstrap-ip>:8001. Kurtosis in-enclave DNS
    # resolves `val-bootstrap` → IP; we look it up at container runtime.
    entrypoint_block = ""
    if role == constants.ROLE_VOTING_JOINER:
        # NOTE: entrypoint_block is a VALUE substituted at {ENTRYPOINT_BLOCK} in
        # the outer .format() template below. .format() does NOT re-process
        # substituted values, so braces here must be SINGLE (literal), NOT the
        # doubled {{ }} used inside the format template itself. Using {{ here
        # would leak literal {{ }} into the bash script (awk/var-expansion bug).
        entrypoint_block = """
BOOTSTRAP_IP="$(getent hosts val-bootstrap | awk '{print $1}' | head -n1)"
if [[ -z "$BOOTSTRAP_IP" ]]; then
  echo "[validator] FATAL: could not resolve val-bootstrap via getent" >&2
  exit 1
fi
ENTRYPOINT_ARG="--entrypoint ${BOOTSTRAP_IP}:8001"
"""
    else:
        entrypoint_block = "ENTRYPOINT_ARG=''"

    # Common args ported from smoke-shared-genesis.sh:102-128. The Jito-only MEV
    # tip args (TIP_ARGS) are emitted only for the Jito image; Agave 4.3.0 lacks
    # them (see _validator_cmd above). genesis_launcher bakes TIP_PAYMENT /
    # TIP_DISTRIBUTION / MERKLE_AUTHORITY into meta.env, so the Jito bootstrap can
    # source them here.
    script = r"""
set -euo pipefail
# Both the Jito (/opt/jito/bin) and Agave (/opt/agave/bin) runtime images keep
# their binaries off the default PATH. Add whichever exists; agave-validator is
# the same binary name in both images (v4.3.0 renamed solana-validator).
export PATH="/opt/jito/bin:/opt/agave/bin:$PATH"
source /data/meta.env

cd /data

# Resolve this container's in-enclave IP (Starlark can't see the future IP).
MY_IP="$(hostname -I | awk '{{print $1}}')"
if [[ -z "$MY_IP" ]]; then
  echo "[validator] FATAL: hostname -I returned no IP" >&2
  exit 1
fi
echo "[validator] role={role} my_ip=$MY_IP identity=${IDENTITY_KEY}"

{ENTRYPOINT_BLOCK}

exec agave-validator \
  --ledger /data/{LEDGER_SUBDIR} \
  --identity /data/{IDENTITY_FILE}.json \
  --vote-account "${VOTE_KEY}" \
  --bind-address "$MY_IP" \
  --public-tpu-address "${{MY_IP}}:8003" \
  --public-tpu-forwards-address "${{MY_IP}}:8004" \
  --public-tvu-address "${{MY_IP}}:8002" \
  --rpc-bind-address 0.0.0.0 \
  --rpc-port 8899 \
  --gossip-port 8001 \
  --dynamic-port-range 8002-8035 \
  --full-rpc-api \
  --rpc-pubsub-enable-block-subscription \
  --rpc-pubsub-enable-vote-subscription \
  --enable-rpc-transaction-history \
{SNAPSHOT_ARGS}  --no-genesis-fetch \
  --no-snapshot-fetch \
  --no-xdp \
  --no-os-network-limits-test \
  --no-poh-speed-test \
  --no-port-check \
  --allow-private-addr \
  --no-wait-for-vote-to-start-leader \
  --wait-for-supermajority 0 \
  --expected-bank-hash "{BANK_HASH}" \
{TIP_ARGS}  --limit-blockstore-size 100000000 \
  --expected-genesis-hash "$GENESIS_HASH" \
  --expected-shred-version "$SHRED_VERSION" \
  --log - \
  $ENTRYPOINT_ARG
""".format(
        role=role,
        LEDGER_SUBDIR=ledger_subdir,
        IDENTITY_FILE=_identity_file(role),
        IDENTITY_KEY=identity_key,
        VOTE_KEY=vote_key,
        ENTRYPOINT_BLOCK=entrypoint_block,
        SNAPSHOT_ARGS=snapshot_args,
        TIP_ARGS=tip_args,
        BANK_HASH=bank_hash,
    )
    return ["bash", "-c", script]


def _identity_file(role):
    """The keypair filename (without .json) for this role's identity."""
    if role == constants.ROLE_VOTING_BOOTSTRAP:
        return "bootstrap-identity"
    return "joiner-identity"


def launch_validator(plan, role, image, genesis_artifact, bank_hash, global_node_selectors={}, extra_files={}):
    """Launch one voting validator against the shared genesis artifact.

    Args:
        plan: the Kurtosis plan
        role: constants.ROLE_VOTING_BOOTSTRAP or constants.ROLE_VOTING_JOINER
        image: the client image (jito or agave)
        genesis_artifact: the files-artifact name returned by generate_genesis
        bank_hash: the slot-0 bank hash captured by bank_hash_probe (passed to
            --expected-bank-hash, coordinated with --wait-for-supermajority 0
            so both validators wait until they see each other in gossip before
            starting PoH — this is what lets a 50/50-stake two-node dev cluster
            reach the 2/3 finalization threshold instead of deadlocking)
        global_node_selectors: optional node selectors
        extra_files: optional dict of {mount_path: files_artifact_name} for
            ADDITIONAL files-artifact mounts beyond the genesis artifact. Used
            by the functional SIG path to mount the shred-stream binary
            (built from the SIG image) onto the bootstrap validator, so
            shred-stream can run inside the bootstrap container (which owns the
            only live blockstore at /data/bootstrap-ledger/rocksdb). The
            shred-stream binary is glibc-2.36-compatible with the Jito/Agave
            bookworm-slim runtime image (verified via probe v3 ldd).

    Returns: struct(service, name, rpc_url, identity_pubkey_var, vote_pubkey_var)
    """
    name = _SERVICE_NAME[role]
    plan.print("Launching validator '{0}' (role={1}, image={2})".format(name, role, image))

    port_assignments = {
        constants.RPC_PORT_ID: constants.RPC_PORT_NUM,
        # WebSocket (pubsub) is a real TCP listener at rpc_port+1; declare it so
        # the host can reach ws://<node>:8900. TCP readiness works normally.
        constants.RPC_PUBSUB_PORT_ID: constants.RPC_PUBSUB_PORT_NUM,
        # UDP ports are NOT declared as Kurtosis ports: port-readiness would
        # time out on UDP (no listener handshake). They are still bound by the
        # validator; we just don't ask Kurtosis to probe them.
    }

    # The genesis artifact is always mounted at /data. extra_files (e.g. the
    # shred-stream binary for the bootstrap) are mounted at their specified
    # paths. Files mounts are set at add_service time, so the shred-stream
    # artifact MUST be built before the bootstrap service is launched.
    files_map = {constants.GENESIS_DATA_MOUNTPOINT: genesis_artifact}
    files_map.update(extra_files)

    config_args = {
        "image": image,
        "entrypoint": ["/usr/bin/tini", "-g", "--"],
        "cmd": _validator_cmd(role, image, bank_hash),
        "ports": shared_utils.get_port_specs(port_assignments),
        "files": files_map,
        "node_selectors": global_node_selectors,
        # PRIVILEGED is REQUIRED: agave 4.3.0 fs/src/dirs.rs:12 hard-asserts
        # io_uring_supported() on Linux; OrbStack's default seccomp makes
        # io_uring_setup return EPERM in non-privileged containers, panicking
        # the validator on the first directory deletion. --privileged clears
        # the seccomp gate (verified: io_uring_setup succeeds privileged,
        # fails EPERM non-privileged). REQUIRES `kurtosis run --privileged`.
        "privileged": True,
    }

    service = plan.add_service(name=name, config=ServiceConfig(**config_args))

    rpc_url = "http://{0}:{1}".format(name, constants.RPC_PORT_NUM)
    ws_url = "ws://{0}:{1}".format(name, constants.RPC_PUBSUB_PORT_NUM)
    plan.print("Validator '{0}' launched; rpc={1} ws={2}".format(name, rpc_url, ws_url))

    return struct(
        service=service,
        name=name,
        rpc_url=rpc_url,
        ws_url=ws_url,
        identity_pubkey_var=_IDENTITY_KEY[role],
        vote_pubkey_var=_VOTE_KEY[role],
    )
