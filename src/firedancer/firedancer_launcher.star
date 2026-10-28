"""Launch the independent full Firedancer binary on the shared genesis."""

constants = import_module("../package_io/constants.star")


def launch_firedancer(plan, genesis_artifact, image):
    script = """
set -euo pipefail
source /data/meta.env
BOOTSTRAP_IP="$(getent hosts val-bootstrap | awk '{print $1}' | head -n1)"
MY_IP="$(hostname -I | awk '{print $1}')"
test -n "$BOOTSTRAP_IP" && test -n "$MY_IP"
mkdir -p /tmp/firedancer/snapshots
chown -R firedancer:firedancer /tmp/firedancer
cat >/tmp/firedancer.toml <<EOF
name = "fd-local"
user = "firedancer"
telemetry = false
[paths]
base = "/tmp/firedancer"
identity_key = "/data/firedancer-identity.json"
vote_account = "/data/firedancer-vote.json"
genesis = "/data/firedancer-ledger/genesis.bin"
[gossip]
entrypoints = ["${BOOTSTRAP_IP}:8001"]
host = "$MY_IP"
port = 8001
[consensus]
expected_genesis_hash = "$GENESIS_HASH"
expected_shred_version = $SHRED_VERSION
wait_for_vote_to_start_leader = false
[snapshots]
genesis_download = false
incremental_snapshots = false
wait_for_peers_timeout_seconds = 600
[snapshots.sources]
servers = ["http://${BOOTSTRAP_IP}:8899"]
[net]
provider = "socket"
interface = "eth0"
bind_address = "$MY_IP"
[hugetlbfs]
max_page_size = "huge"
[accounts]
max_accounts = 1048576
[development.accdb]
partition_size_gib = 1
[tiles.rserve]
shred_storage_limit_gib = 2
[tiles.gui]
enabled = false
[layout]
net_tile_count = 1
gossvf_tile_count = 1
execle_tile_count = 1
verify_tile_count = 1
execrp_tile_count = 1
snapdc_tile_count = 1
snapin_tile_count = 1
snapzp_tile_count = 1
sign_tile_count = 2
[development]
sandbox = false
[development.gossip]
allow_private_address = true
[development.genesis]
validate_genesis_hash = false
EOF
firedancer configure init hugetlbfs --config /tmp/firedancer.toml
firedancer configure check sysctl --config /tmp/firedancer.toml
exec firedancer run --config /tmp/firedancer.toml
"""
    service = plan.add_service(
        name="val-firedancer",
        config=ServiceConfig(
            image=image,
            entrypoint=["/usr/bin/tini", "-g", "--"],
            cmd=["bash", "-c", script],
            files={constants.GENESIS_DATA_MOUNTPOINT: genesis_artifact},
            privileged=True,
        ),
    )
    return struct(service=service, name="val-firedancer", identity_pubkey_var="FIREDANCER_IDENTITY", vote_pubkey_var="FIREDANCER_VOTE")
