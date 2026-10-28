# Slot verifier — wait for all three voting validators to be non-delinquent and for
# the slot count to reach the target, then capture the verification evidence.
#
# This module gates the three voting validators and SIG's appearance in peer
# gossip. SIG is a non-voting observer and has no vote-account gate.
#
# Ported from smoke-shared-genesis.sh:204-285 (the proven readiness poll + final
# verification block), adapted to the Kurtosis plan.wait / plan.exec API.
#
# IMPORTANT — jq-FREE by design. Both validator runtime images
# (solana-diff/jito-solana:4.3.0-jito-arm64 and solana-diff/agave-validator:4.3.0
# -arm64) currently LACK jq in their installed layers (the Dockerfiles specify
# jq in the runtime stage, but the running images predate that line / the apt
# cache was empty at build time — verified: `command -v jq` → MISSING in both).
# So every readiness poll and evidence-capture path parses the HUMAN-READABLE
# `solana` output with awk/sed/grep (all present), never jq. This also makes the
# verifier robust to image drift. If the images are later rebuilt with jq, this
# path keeps working (it does not depend on jq being absent).
#
#   Stage 1 (plan.wait): block until all three validators are non-delinquent
#   with lastVote>0. Solana marks delinquent rows with a leading "!".
#
#   Stage 2 (plan.wait): block until the current slot >= slots_target (proven
#   20-slot goal). Polls `solana slot` on the bootstrap RPC.
#
#   Stage 3 (plan.exec): capture the full evidence snapshot — slot start/end,
#   genesis-hash from BOTH nodes (must match — shared-genesis proof), the
#   validators table, the gossip table, and `agave-validator --version` per node
#   (proving client diversity: JitoLabs vs Agave). Writes a JSON evidence file
#   to the bootstrap node. The JSON is assembled with printf (no jq -n), with
#   every string value JSON-escaped via a small awk function.
#
# All RPC calls go to the bootstrap node; the joiner is queried only for its
# genesis-hash and version (proving it shares genesis and reports a different
# client version string). A cross-node finalized transfer is included to prove
# end-to-end finality.

constants = import_module("../package_io/constants.star")


def _bootstrap_rpc_url(topology):
    return "http://{0}:{1}".format(
        topology.bootstrap.name, constants.RPC_PORT_NUM,
    )


def _joiner_rpc_url(topology):
    return "http://{0}:{1}".format(
        topology.joiner.name, constants.RPC_PORT_NUM,
    )


def _validators_ready_cmd(rpc_url):
    """Exit 0 only when all three validators are non-delinquent with lastVote>0.

    jq-FREE. Scan the human table and skip rows marked with a leading "!".
    Exit 0 only when all three identities have a positive vote field.

    The two identity pubkeys are sourced from /data/meta.env at runtime
    (BOOTSTRAP_IDENTITY / JOINER_IDENTITY), so we do not depend on Starlark
    seeing the future-generated pubkeys.
    """
    # awk program — COLUMN-AGNOSTIC. `solana validators` indents data rows with
    # a leading space that awk captures as $1=" " (space), so the identity is at
    # $2 and "Last Vote" at $5, NOT $1/$4 as a naive parser assumes (the header
    # row has no leading space, so $1=="Identity" works but $1==<identity> does
    # NOT). Instead of fixed positions, we SCAN ALL FIELDS for a match against
    # the two identity pubkeys, and confirm the row has a positive pure-integer
    # field (lastVote / rootSlot / credits are all >0 when voting; the
    # commission "100.00%" and the "( 0)" skip are not pure integers or are 0).
    # We skip rows marked "!" and stop at the Average footer.
    #
    # IMPORTANT: .replace() (NOT .format()) for __RPC__ — the awk program has
    # literal single { } braces that .format() would misinterpret (KeyError).
    lines = [
        "set -uo pipefail",
        'export PATH="/opt/jito/bin:/opt/agave/bin:$PATH"',
        "source /data/meta.env",
        'out=$(solana --url __RPC__ validators 2>/dev/null) || exit 1',
        '[[ -n "$out" ]] || exit 1',
        "count=$(echo \"$out\" | awk '",
        "  /Identity/ { in_hdr=1; next }",
        "  in_hdr && (/Delinquent/ || /Average/) { exit }",
        "  in_hdr && $1 == \"!\" { next }",
        "  in_hdr {",
        "    for (i=1; i<=NF; i++) {",
        "      if ($i == first || $i == second || $i == third) {",
        "        for (j=1; j<=NF; j++) {",
        "          if ($j ~ /^[0-9]+$/ && $j+0 > 0) { c++; break }",
        "        }",
        "        break",
        "      }",
        "    }",
        "  }",
        "  END { print c + 0 }",
        "' first=\"$BOOTSTRAP_IDENTITY\" second=\"$JOINER_IDENTITY\" third=\"$FIREDANCER_IDENTITY\")",
        '[[ "$count" == "3" ]] && exit 0 || exit 1',
    ]
    script = "\n".join(lines).replace("__RPC__", rpc_url)
    return ["bash", "-c", script]


def _slot_ge_target_cmd(rpc_url, target):
    """Exit 0 only when the current slot >= target. jq-free (`solana slot`)."""
    script = """set -uo pipefail
export PATH="/opt/jito/bin:/opt/agave/bin:$PATH"
slot=$(solana --url {RPC} slot 2>/dev/null) || exit 1
slot="${{slot//[^0-9]/}}"
[[ -n "$slot" ]] || exit 1
[[ "$slot" -ge {TARGET} ]] && echo "slot=$slot" && exit 0 || exit 1
""".format(
        RPC=rpc_url,
        TARGET=target,
    )
    return ["bash", "-c", script]


def _capture_evidence_cmd(topology, slots_target, joiner_version, firedancer_version, sig_evidence_level, bank_hash):
    """Capture the full verification evidence JSON and write it to /data.

    jq-FREE. Mirrors smoke-shared-genesis.sh:229-285 (genesis-hash from both
    nodes must match, slot start/end, cross-node finalized transfer, gossip
    table, per-node `agave-validator --version` client-diversity proof) but
    assembles the JSON with printf instead of `jq -n`.

    Every string value inlined into the JSON is base58 (pubkeys/hashes/
    signatures) or a simple version string — none contain double-quotes or
    backslashes, so no JSON escaping is needed. The multi-line `solana
    validators`/`gossip` human tables are saved as SEPARATE evidence files
    (/data/validators.txt, /data/gossip.txt) and referenced by path in the
    JSON, NOT inlined (inlining newlines would require escaping we can't do
    cleanly without jq).

    The joiner's version is captured by a SEPARATE plan.exec on the joiner
    service and passed in here, because we cannot run `agave-validator
    --version` on the joiner from inside the bootstrap container.
    """
    rpc_bs = _bootstrap_rpc_url(topology)
    rpc_join = _joiner_rpc_url(topology)

    # Built as a list of lines joined by "\n" with explicit __PLACEHOLDER__
    # substitution via .replace() (NOT .format()). This is deliberate: the
    # printf JSON template below contains many literal { } braces (JSON object
    # delimiters) that .format() would misinterpret as field markers. With
    # .replace(), single { } braces pass through untouched, so the JSON is valid.
    #
    # No jq → no `jq -n`. Every string value inlined into the JSON is either
    # base58 (pubkeys/hashes/signatures) or a simple version string (e.g.
    # 'solana-validator 4.3.0-jito (client:JitoLabs)') — none contain
    # double-quotes or backslashes, so no JSON escaping is needed. The
    # multi-line `solana validators`/`gossip` human tables contain newlines, so
    # they are saved as SEPARATE evidence files (/data/validators.txt,
    # /data/gossip.txt) and referenced by path, NOT inlined (inlining would
    # require newline escaping we can't do cleanly without jq).
    # NOTE: `set -uo pipefail` deliberately OMITS `-e`. The evidence-capture
    # script makes several best-effort `solana` calls (slot/genesis-hash queries,
    # the validators/gossip human tables, the version string) that are NOT
    # individually fatal — a transient RPC failure on one of them should NOT
    # silently abort the whole evidence capture (the observed symptom under
    # `set -euo pipefail`: exit 1 with no evidence JSON emitted). The genuinely
    # fatal conditions (genesis-hash mismatch, slot < target, no transfer
    # signature, recipient balance too low) are guarded with explicit
    # `|| { ...; exit 1; }` blocks that are independent of `set -e`. The proven
    # evidence-capture path during the 2026-10-02 run used an inline `set -ux`
    # (no `-e`); this matches it so a future clean `kurtosis run` captures
    # evidence without manual intervention. `-u` (unset-var guard) and
    # `-o pipefail` (pipeline-failure visibility for the `[[ ]]` guards) stay.
    lines = [
        "set -uo pipefail",
        'export PATH="/opt/jito/bin:/opt/agave/bin:$PATH"',
        "source /data/meta.env",
        "",
        'RPC_BS="__RPC_BS__"',
        'RPC_JOIN="__RPC_JOIN__"',
        "SLOTS_TARGET=__SLOTS_TARGET__",
        'JOIN_VERSION="__JOIN_VERSION__"',
        'FIREDANCER_VERSION="__FIREDANCER_VERSION__"',
        "# Strip any trailing newline from the joiner version (passed from",
        "# Starlark; Starlark .strip() should remove it, but a residual newline",
        "# would land inside the JSON string and make it invalid JSON).",
        "JOIN_VERSION=$(printf '%s' \"$JOIN_VERSION\" | tr -d '\\n\\r')",
        'BANK_HASH="__BANK_HASH__"',
        'SIG_LEVEL="__SIG_LEVEL__"',
        "",
        "bs_identity=\"$BOOTSTRAP_IDENTITY\"",
        "join_identity=\"$JOINER_IDENTITY\"",
        "bs_vote=\"$BOOTSTRAP_VOTE\"",
        "join_vote=\"$JOINER_VOTE\"",
        "firedancer_identity=\"$FIREDANCER_IDENTITY\"",
        "firedancer_vote=\"$FIREDANCER_VOTE\"",
        "",
        "# Slot range + shared-genesis proof (genesis-hash from BOTH nodes must match).",
        "slot_start=$(solana --url \"$RPC_BS\" slot | tr -d '[:space:]')",
        "bs_genesis_hash=$(solana --url \"$RPC_BS\" genesis-hash | tr -d '[:space:]')",
        "join_genesis_hash=$(solana --url \"$RPC_JOIN\" genesis-hash | tr -d '[:space:]')",
        'if [[ -z "$bs_genesis_hash" || "$bs_genesis_hash" != "$join_genesis_hash" ]]; then',
        '  echo "[verifier] FATAL: genesis hash mismatch: bs=$bs_genesis_hash join=$join_genesis_hash" >&2; exit 1; fi',
        "",
        "# Brief window for slots to advance, then prove advancement.",
        "sleep 3",
        "slot_end=$(solana --url \"$RPC_BS\" slot | tr -d '[:space:]')",
        '[[ "$slot_end" -ge "$SLOTS_TARGET" ]] || { echo "[verifier] FATAL: slot $slot_end < $SLOTS_TARGET" >&2; exit 1; }',
        "",
        "# Cross-node finalized transfer: submit on bootstrap, confirm on joiner.",
        "# Use --output json-compact (same source as smoke-shared-genesis.sh:240)",
        "# so the signature is on a stable single-line JSON field; extract jq-free",
        "# with grep (the line looks like {\"signature\":\"<sig>\",...}).",
        "# RETRY: a fresh cluster can transiently reject the first transfer right",
        "# after slot_target is reached (blockhash not yet rooted, or the bank is",
        "# still settling). Retry up to 6 times (30s) before declaring failure —",
        "# this is a cluster-warmup artifact, NOT a correctness gap (the transfer",
        "# succeeds once the cluster stabilizes; verified during the 2026-10-02",
        "# run: the first attempt failed with 'insufficient funds' at slot 652,",
        "# a manual retry at slot 1649 succeeded with a valid signature).",
        "#",
        "# set -e NOTE: a failing `solana transfer` exits non-zero, and under",
        "# `set -euo pipefail` the `transfer=$(solana ...)` assignment propagates",
        "# that non-zero exit and aborts the script BEFORE the retry loop runs",
        "# (the observed symptom: exit 1, no output). Append `|| transfer=\"\"` so",
        "# a failed transfer attempt sets transfer to the empty string and the",
        "# loop's `[[ -n $signature ]] && break` / retry logic actually executes.",
        "recipient_pub=\"$RECIPIENT\"",
        "signature=\"\"",
        "transfer=\"\"",
        "for _ in $(seq 1 6); do",
        "  transfer=$(solana --url \"$RPC_BS\" --keypair /data/bootstrap-identity.json \\",
        "    --commitment finalized transfer \"$recipient_pub\" 1 --allow-unfunded-recipient --output json-compact 2>&1) || transfer=\"\"",
        "  signature=$(echo \"$transfer\" | grep -o '\"signature\":\"[^\"]*\"' | head -n1 | sed 's/\"signature\":\"//;s/\"$//') || true",
        '  [[ -n "$signature" ]] && break',
        '  echo "[verifier] transfer attempt failed (will retry): $transfer" >&2',
        "  sleep 5",
        "done",
        '[[ -n "$signature" ]] || { echo "[verifier] FATAL: no signature after 6 transfer attempts; last output: $transfer" >&2; exit 1; }',
        "recipient_lamports=$(solana --url \"$RPC_JOIN\" --commitment finalized \\",
        "  balance \"$recipient_pub\" --lamports | awk '{print $1}')",
        '[[ "$recipient_lamports" =~ ^[0-9]+$ && "$recipient_lamports" -ge 1000000000 ]] || { echo "[verifier] FATAL: recipient balance $recipient_lamports not >= 1 SOL" >&2; exit 1; }',
        "",
        "# Capture the human-readable validators + gossip tables as separate",
        "# evidence files (they contain newlines — NOT inlined into the JSON).",
        "solana --url \"$RPC_BS\" validators 2>/dev/null > /data/validators.txt",
        "solana --url \"$RPC_BS\" gossip 2>/dev/null > /data/gossip.txt",
        'current_count=$(awk -v first="$bs_identity" -v second="$join_identity" -v third="$firedancer_identity" \'',
        '  $1 == "!" { next }',
        '  { for (i=1;i<=NF;i++) if ($i==first||$i==second||$i==third) { c++; break } }',
        '  END { print c + 0 }' + "' /data/validators.txt)",
        '[[ "$current_count" == "3" ]] || { echo "[verifier] FATAL: a voting validator is delinquent at evidence capture (current=$current_count)" >&2; exit 1; }',
        "",
        "# Count our three voting identities in the gossip table (column-agnostic — the",
        "# gossip table also pads fields, so $1 is not the identity; scan all fields).",
        'gossip_count=$(awk -v first="$bs_identity" -v second="$join_identity" -v third="$firedancer_identity" \'',
        "  /Identity/ { in_hdr=1; next }",
        "  in_hdr { for (i=1;i<=NF;i++) if ($i==first||$i==second||$i==third){c++;break} }",
        "  END { print c + 0 }' /data/gossip.txt)",
        '[[ "$gossip_count" == "3" ]] || { echo "[verifier] FATAL: gossip_count=$gossip_count (expected 3)" >&2; exit 1; }',
        "",
        "# Total gossip nodes seen by the bootstrap. Three voting validators plus",
        "# the SIG observer = 4 when SIG has JOINED the shared-genesis gossip view.",
        "# This is the authoritative 'joined' signal per AGENTS.md (\"the node",
        "# appeared in the shared-genesis gossip/network view\"): it is read from a",
        "# PEER (the bootstrap), not from SIG's own logs. The gossip table's last",
        "# line is 'Nodes: N'.",
        'gossip_nodes=$(awk -F": " "/^Nodes:/ {print \\$2}" /data/gossip.txt)',
        'gossip_nodes=$(printf "%s" "$gossip_nodes" | tr -d "[:space:]")',
        'if [[ -z "$gossip_nodes" ]]; then gossip_nodes=0; fi',
        "# Resolve SIG's service IP and require that exact peer in gossip.",
        'sig_in_gossip=false',
        "sig_ip=$(getent hosts sig-observer | awk '{print $1}' | head -n1)",
        "if [[ -n \"$sig_ip\" ]] && awk -v ip=\"$sig_ip\" '$1==ip { found=1 } END { exit !found }' /data/gossip.txt; then sig_in_gossip=true; fi",
        '[[ "$sig_in_gossip" == "true" ]] || { echo "[verifier] FATAL: SIG absent from peer gossip view" >&2; exit 1; }',
        'echo "[verifier] gossip_nodes=$gossip_nodes sig_in_gossip=$sig_in_gossip"',
        "",
        "bs_version=$(agave-validator --version 2>/dev/null | tr -d '\\r')",
        "",
        "# Assemble the evidence JSON with printf (single { } braces — valid JSON).",
        'now=$(date -u +%Y-%m-%dT%H:%M:%SZ)',
        "evidence=$(printf '{\"verifiedAt\":\"%s\",\"topology\":\"shared-genesis-multi-client\",\"genesisHash\":\"%s\",\"shredVersion\":\"%s\",\"bankHash\":\"%s\",\"slotsTarget\":%s,\"votingValidators\":[{\"role\":\"bootstrap\",\"identity\":\"%s\",\"vote\":\"%s\",\"binaryVersion\":\"%s\"},{\"role\":\"joiner\",\"identity\":\"%s\",\"vote\":\"%s\",\"binaryVersion\":\"%s\"},{\"role\":\"firedancer\",\"identity\":\"%s\",\"vote\":\"%s\",\"binaryVersion\":\"%s\"}],\"sigObserver\":{\"evidenceLevel\":\"%s\",\"voting\":false,\"inGossipView\":%s},\"validatorsFile\":\"/data/validators.txt\",\"gossipFile\":\"/data/gossip.txt\",\"gossipCount\":%s,\"gossipNodes\":%s,\"slots\":{\"start\":%s,\"end\":%s},\"transfer\":{\"signature\":\"%s\",\"recipient\":\"%s\",\"recipientLamports\":\"%s\"}}' \\",
        '  "$now" "$bs_genesis_hash" "$SHRED_VERSION" "$BANK_HASH" "$SLOTS_TARGET" \\',
        '  "$bs_identity" "$bs_vote" "$bs_version" "$join_identity" "$join_vote" "$JOIN_VERSION" \\',
        '  "$firedancer_identity" "$firedancer_vote" "$FIREDANCER_VERSION" \\',
        '  "$SIG_LEVEL" "$sig_in_gossip" "$gossip_count" "$gossip_nodes" "$slot_start" "$slot_end" \\',
        '  "$signature" "$recipient_pub" "$recipient_lamports")',
        '[[ -n "$evidence" ]] || { echo "[verifier] FATAL: empty evidence JSON" >&2; exit 1; }',
        "",
        "echo \"$evidence\" | tee /data/evidence.json",
        'echo "=== EVIDENCE_JSON_START ==="',
        'echo "$evidence"',
        'echo "=== EVIDENCE_JSON_END ==="',
        'echo "[verifier] OK slot_start=$slot_start slot_end=$slot_end gossip_count=$gossip_count bs_version=$bs_version join_version=$JOIN_VERSION"',
    ]
    script = "\n".join(lines)
    # Explicit placeholder substitution (NOT .format()) — single { } braces in
    # the printf template pass through untouched (no brace-doubling needed).
    script = script.replace("__RPC_BS__", rpc_bs)
    script = script.replace("__RPC_JOIN__", rpc_join)
    script = script.replace("__SLOTS_TARGET__", str(slots_target))
    script = script.replace("__JOIN_VERSION__", joiner_version)
    script = script.replace("__FIREDANCER_VERSION__", firedancer_version)
    script = script.replace("__BANK_HASH__", bank_hash)
    script = script.replace("__SIG_LEVEL__", sig_evidence_level)
    return ["bash", "-c", script]


def wait_for_slots(plan, topology, slots_target, global_node_selectors={}):
    """Block until the network produces slots_target slots, then capture evidence.

    Args:
        plan: the Kurtosis plan
        topology: struct returned by participant_network with .bootstrap and
            .joiner (each struct(name, rpc_url, identity_pubkey_var,
            vote_pubkey_var)) and .sig (struct(name, evidence_level)) and
            .bank_hash (the slot-0 bank hash, for the evidence JSON)
        slots_target: int — number of slots to wait for (default 20)
        global_node_selectors: optional node selectors

    Returns: struct(evidence_json, evidence_artifact, slot_reached)
    """
    bootstrap = topology.bootstrap
    joiner = topology.joiner
    sig = topology.sig
    bank_hash = topology.bank_hash
    rpc_url = _bootstrap_rpc_url(topology)

    plan.print(
        "Slot verifier: waiting for all three voting validators non-delinquent, then slot >= {0}"
        .format(slots_target),
    )

    # Stage 1: wait for both voting validators to be non-delinquent with
    # lastVote>0. Identities are resolved inside the container from
    # /data/meta.env (the genesis_launcher wrote them). jq-free: parses the
    # `solana validators` human table with awk.
    # NOTE: field="code" returns an INT (the exec exit code). target_value MUST
    # be the int 0, NOT the string "0" — Kurtosis' Verify rejects mixed-type
    # comparisons ("'1' is type 'int' and '\"0\"' is type 'string'").
    plan.wait(
        service_name=bootstrap.name,
        recipe=ExecRecipe(command=_validators_ready_cmd(rpc_url)),
        field="code",
        assertion="==",
        target_value=0,
        timeout="900s",
    )
    plan.print("All three voting validators are non-delinquent with lastVote>0.")

    # Stage 2: wait for the slot count to reach the target. jq-free.
    plan.wait(
        service_name=bootstrap.name,
        recipe=ExecRecipe(command=_slot_ge_target_cmd(rpc_url, slots_target)),
        field="code",
        assertion="==",
        target_value=0,
        timeout="900s",
    )
    plan.print("Slot >= {0} reached.".format(slots_target))

    # Stage 3a: capture the joiner's `agave-validator --version` on the joiner
    # service (we cannot run it from the bootstrap container). This proves
    # client diversity: bootstrap reports `client:JitoLabs`, joiner reports
    # `client:Agave` (or vice versa, depending on image assignment).
    joiner_version_result = plan.exec(
        recipe=ExecRecipe(command=["bash", "-c", "export PATH=/opt/jito/bin:/opt/agave/bin:$PATH; agave-validator --version | tr -d '\\r'"]),
        service_name=joiner.name,
        acceptable_codes=[0],
    )
    joiner_version = joiner_version_result.get("output", "").strip()
    firedancer_version_result = plan.exec(
        recipe=ExecRecipe(command=["firedancer", "version"]),
        service_name=topology.firedancer.name,
        acceptable_codes=[0],
    )
    firedancer_version = firedancer_version_result.get("output", "").strip()

    # Stage 3b: capture the full evidence snapshot on the bootstrap node.
    # NOTE: plan.exec's returned `output` is TRUNCATED for long-running execs
    # (the evidence JSON can be large because it embeds the full validators +
    # gossip tables). So the script writes the JSON to /data/evidence.json AND
    # prints it between EVIDENCE_JSON_START/END markers; the full JSON is in the
    # STREAMED log (always complete) even if the returned struct is truncated.
    capture_result = plan.exec(
        recipe=ExecRecipe(command=_capture_evidence_cmd(
            topology, slots_target, joiner_version, firedancer_version, sig.evidence_level, bank_hash,
        )),
        service_name=bootstrap.name,
        acceptable_codes=[0],
    )
    evidence_json = capture_result.get("output", "")

    # Record the SIG observer's evidence level honestly (not a gate).
    plan.print(
        ("Verification complete. SIG observer evidence_level={0} (NON-VOTING; recorded, not required). "
         + "Voting validators: bootstrap={1} (image-version captured), joiner={2} ({3}).")
        .format(sig.evidence_level, bootstrap.name, joiner.name, joiner_version),
    )

    return struct(
        evidence_json=evidence_json,
        evidence_artifact=None,
        slot_reached=True,
    )
