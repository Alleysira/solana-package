# Genesis launcher — generates the shared genesis artifact ONCE.
#
# Mirrors ethereum-package's genesis_launcher: a single `plan.run_sh` produces
# a files-artifact containing the genesis ledger + per-node ledger copies + a
# shell-sourceable meta.env carrying genesis_hash, shred_version, and all
# pubkeys. Every validator mounts this artifact at /data.
#
# Ported from the proven smoke-shared-genesis.sh pattern (lines 54-166):
#   1. keygen all identities/votes/stakes/faucet/tip/merkle/recipient
#   2. solana-keygen bls_pubkey ×2 (bootstrap + joiner)
#   3. ONE solana-genesis with two --bootstrap-validator triples + bls pubkeys
#   4. copy the genesis ledger per-node (bootstrap/joiner)
#   5. write meta.env (shell-sourceable KEY=VALUE)
#
# No bank-hash probe here: capturing the slot-0 bank hash needs a probe
# validator, but plan.run_sh containers can't be privileged (agave
# fs/src/dirs.rs:12 hard-asserts io_uring_supported(); OrbStack's default
# seccomp returns EPERM), and the validators don't pass --wait-for-supermajority
# (which is what .requires --expected-bank-hash). See solana_validator_launcher.
#
# The run_sh executes in the GENESIS_IMAGE (Agave, which has solana-genesis +
# solana-keygen + agave-validator). The GENESIS_IMAGE runs as the non-root
# `validator` user (uid 1000), and /data is root-owned/absent — so genesis
# writes to a writable workdir (WORK=/tmp/genesis) and stores THAT dir. The
# validators then mount the artifact at /data, so the artifact's root contents
# (meta.env, bootstrap-identity.json, bootstrap-ledger/, etc.) appear at
# /data/... — matching every validator's path reference. meta.env carries only
# pubkeys/values (no paths), so the workdir-name swap is transparent.

constants = import_module("../package_io/constants.star")
shared_utils = import_module("../shared_utils/shared_utils.star")

GENESIS_ARTIFACT_NAME = "solana-genesis-data"

# Writable workdir for the genesis run_sh (the GENESIS_IMAGE runs as uid 1000,
# which cannot create /data). Stored as the files artifact; validators mount
# its contents at /data.
GENESIS_WORKDIR = "/tmp/genesis"


def generate_genesis(plan, genesis_config):
    """Run the genesis generator in the genesis image, return the artifact name.

    Returns: the files-artifact name string (mount at /data).
    """
    plan.print("Generating shared genesis (single run_sh)")

    # The genesis-generation script. Runs in GENESIS_IMAGE (Agave). Writes the
    # genesis ledger + per-node ledger copies + meta.env under WORK.
    #
    # IMPORTANT: plan.run_sh(run=...) in Kurtosis 1.20.0 does NOT accept real
    # newline characters — a script with real newlines (r""" or triple-quoted)
    # fails at runtime with "/bin/sh: N: Syntax error: ';' unexpected" where N
    # is the LAST line (Kurtosis mangles real newlines during delivery). The
    # script MUST be a regular string built with explicit \n escapes. We build
    # it as a list of lines joined by "\n". Consequences:
    #   - No heredocs (rely on real newlines): use `{ echo ...; } > file`.
    #   - No `\<newline>` line-continuations (eaten by regular strings): put
    #     long commands on single logical lines.
    #   - .format() is NOT called on the joined string (that would require
    #     escaping every literal { } in awk programs / function defs as
    #     {{ }}); the 7 genesis knobs are interpolated on their individual
    #     env-var lines only, via per-line .format().
    # The validator/sig launchers use ["bash","-c",script] via plan.exec,
    # which does NOT have this bug (argv passed directly) — only
    # plan.run_sh(run=...) is affected. See memory kurtosis-run-sh-newlines.
    W = GENESIS_WORKDIR
    genesis_lines = [
        "set -eu",
        "# Agave runtime image keeps binaries under /opt/agave/bin (NOT on PATH).",
        'export PATH="/opt/agave/bin:$PATH"',
        # WORK is a writable dir (uid-1000 `validator` user cannot create /data).
        # The validators mount the stored artifact at /data, so WORK's contents
        # become /data/... — pubkeys in meta.env are path-independent.
        'WORK="{0}"'.format(W),
        "mkdir -p \"$WORK\"",
        "cd \"$WORK\"",
        "",
        'GEN_CLUSTER_TYPE="{0}"'.format(genesis_config["cluster_type"]),
        # Alpenglow changes PoH to low-power mode and injects the genesis
        # certificate account, so it must be decided at genesis time.
        'GEN_ALPENGLLOW_ARGS="{0}"'.format("--alpenglow" if genesis_config.get("alpenglow", False) else ""),
        'GEN_HASHES_PER_TICK="{0}"'.format(genesis_config["hashes_per_tick"]),
        'GEN_TICKS_PER_SLOT="{0}"'.format(genesis_config["ticks_per_slot"]),
        'GEN_SLOTS_PER_EPOCH="{0}"'.format(genesis_config["slots_per_epoch"]),
        'GEN_FAUCET_LAMPORTS="{0}"'.format(genesis_config["faucet_lamports"]),
        'GEN_BS_LAMPORTS="{0}"'.format(genesis_config["bootstrap_validator_lamports"]),
        'GEN_BS_STAKE_LAMPORTS="{0}"'.format(genesis_config["bootstrap_validator_stake_lamports"]),
        'GEN_FD_STAKE_LAMPORTS="{0}"'.format(genesis_config["firedancer_stake_lamports"]),
        "",
        'echo "[genesis] keygen identities/votes/stakes/faucet/tip/merkle/recipient"',
        # Single-line for-loop (no backslash continuation — would be eaten).
        'for key in bootstrap-identity bootstrap-vote bootstrap-stake joiner-identity joiner-vote joiner-stake firedancer-identity firedancer-vote firedancer-stake faucet tip-payment tip-distribution merkle-authority recipient; do solana-keygen new --no-bip39-passphrase --silent --force --outfile "$WORK/$key.json" >/dev/null; done',
        "",
        'pubkey() { solana-keygen pubkey "$WORK/$1.json"; }',
        'bootstrap_identity="$(pubkey bootstrap-identity)"',
        'bootstrap_vote="$(pubkey bootstrap-vote)"',
        'bootstrap_stake="$(pubkey bootstrap-stake)"',
        'joiner_identity="$(pubkey joiner-identity)"',
        'joiner_vote="$(pubkey joiner-vote)"',
        'joiner_stake="$(pubkey joiner-stake)"',
        'firedancer_identity="$(pubkey firedancer-identity)"',
        'firedancer_vote="$(pubkey firedancer-vote)"',
        'firedancer_stake="$(pubkey firedancer-stake)"',
        'recipient="$(pubkey recipient)"',
        'tip_payment="$(pubkey tip-payment)"',
        'tip_distribution="$(pubkey tip-distribution)"',
        'merkle_authority="$(pubkey merkle-authority)"',
        'bootstrap_bls="$(solana-keygen bls_pubkey "$WORK/bootstrap-identity.json")"',
        'joiner_bls="$(solana-keygen bls_pubkey "$WORK/joiner-identity.json")"',
        'firedancer_bls="$(solana-keygen bls_pubkey "$WORK/firedancer-identity.json")"',
        "",
        'echo "[genesis] running solana-genesis (two bootstrap validators plus staked Firedancer account)"',
        '{ echo "validator_accounts:"; echo "  - balance_lamports: $GEN_BS_LAMPORTS"; echo "    stake_lamports: $GEN_FD_STAKE_LAMPORTS"; echo "    identity_account: $firedancer_identity"; echo "    vote_account: $firedancer_vote"; echo "    stake_account: $firedancer_stake"; echo "    bls_pubkey: $firedancer_bls"; } > "$WORK/firedancer-validator.yaml"',
        # Single-line solana-genesis invocation (was multi-line with \ continuations).
        'genesis_output="$(solana-genesis --ledger "$WORK/genesis-ledger" --bootstrap-validator "$bootstrap_identity" "$bootstrap_vote" "$bootstrap_stake" --bootstrap-validator "$joiner_identity" "$joiner_vote" "$joiner_stake" --bootstrap-validator-bls-pubkey "$bootstrap_bls" --bootstrap-validator-bls-pubkey "$joiner_bls" --validator-accounts-file "$WORK/firedancer-validator.yaml" --faucet-pubkey "$WORK/faucet.json" --faucet-lamports "$GEN_FAUCET_LAMPORTS" --bootstrap-validator-lamports "$GEN_BS_LAMPORTS" --bootstrap-validator-stake-lamports "$GEN_BS_STAKE_LAMPORTS" --cluster-type "$GEN_CLUSTER_TYPE" --hashes-per-tick "$GEN_HASHES_PER_TICK" --ticks-per-slot "$GEN_TICKS_PER_SLOT" --slots-per-epoch "$GEN_SLOTS_PER_EPOCH" $GEN_ALPENGLLOW_ARGS)"',
        # grep+awk extraction (no .format on joined string → literal braces OK).
        # \\$2 in Starlark → \$2 → bash double-quote → $2 → awk field 2.
        'genesis_hash="$(echo "$genesis_output" | grep "Genesis hash:" | awk -F": " "{print \\$2}" | tr -d "[:space:]")"',
        'shred_version="$(echo "$genesis_output" | grep "Shred version:" | awk -F": " "{print \\$2}" | tr -d "[:space:]")"',
        'if [ -z "$genesis_hash" ] || ! echo "$shred_version" | grep -Eq "^[0-9]+$"; then echo "[genesis] FATAL: could not parse genesis_hash/shred_version" >&2; echo "$genesis_output" >&2; exit 1; fi',
        'echo "[genesis] genesis_hash=$genesis_hash shred_version=$shred_version"',
        "",
        'mkdir -p "$WORK/bootstrap-ledger" "$WORK/joiner-ledger" "$WORK/firedancer-ledger" "$WORK/probe-ledger"',
        'cp -a "$WORK/genesis-ledger/." "$WORK/bootstrap-ledger/"',
        'cp -a "$WORK/genesis-ledger/." "$WORK/joiner-ledger/"',
        'cp -a "$WORK/genesis-ledger/." "$WORK/firedancer-ledger/"',
        'cp -a "$WORK/genesis-ledger/." "$WORK/probe-ledger/"',
        "",
        "# The slot-0 bank hash is captured by a SEPARATE privileged probe service",
        "# (bank_hash_probe.star) that runs agave-validator on probe-ledger. It can't",
        "# run inside this run_sh (plan.run_sh containers are not privileged even",
        "# under `kurtosis run --privileged`; agave hard-asserts io_uring_supported(),",
        "# which OrbStack's default seccomp EPERMs). The probe writes BANK_HASH into",
        "# meta.env so the voting validators source it for --expected-bank-hash. See",
        "# bank_hash_probe.star and solana_validator_launcher.star.",
        "",
        "# Write the shell-sourceable meta.env consumed by every validator.",
        "# (No heredoc — run_sh mangles real newlines; use a { echo; } group.)",
        '{ echo "GENESIS_HASH=$genesis_hash"; echo "SHRED_VERSION=$shred_version"; echo "BOOTSTRAP_IDENTITY=$bootstrap_identity"; echo "BOOTSTRAP_VOTE=$bootstrap_vote"; echo "BOOTSTRAP_STAKE=$bootstrap_stake"; echo "JOINER_IDENTITY=$joiner_identity"; echo "JOINER_VOTE=$joiner_vote"; echo "JOINER_STAKE=$joiner_stake"; echo "FIREDANCER_IDENTITY=$firedancer_identity"; echo "FIREDANCER_VOTE=$firedancer_vote"; echo "FIREDANCER_STAKE=$firedancer_stake"; echo "RECIPIENT=$recipient"; echo "TIP_PAYMENT=$tip_payment"; echo "TIP_DISTRIBUTION=$tip_distribution"; echo "MERKLE_AUTHORITY=$merkle_authority"; echo "BOOTSTRAP_BLS=$bootstrap_bls"; echo "JOINER_BLS=$joiner_bls"; echo "FIREDANCER_BLS=$firedancer_bls"; } > "$WORK/meta.env"',
        "",
        'echo "[genesis] meta.env written. Contents:"',
        "cat \"$WORK/meta.env\"",
        'echo "[genesis] DONE"',
    ]
    genesis_script = "\n".join(genesis_lines)

    # plan.run_sh with acceptable_codes=[0] makes Kurtosis fail the plan
    # automatically if the genesis script exits non-zero, so we do NOT branch
    # on result.code here — doing so would try to evaluate a runtime_value at
    # plan-construction time and break dry-run mode.
    # store= captures WORK's contents as the files artifact; validators mount
    # that artifact at /data so WORK/<file> becomes /data/<file>.
    result = plan.run_sh(
        run = genesis_script,
        image = constants.GENESIS_IMAGE,
        store = [StoreSpec(src=GENESIS_WORKDIR, name=GENESIS_ARTIFACT_NAME)],
        acceptable_codes = [0],
        wait = "300s",
    )

    plan.print("Genesis artifact '" + GENESIS_ARTIFACT_NAME + "' produced")
    return result.files_artifacts[0]
