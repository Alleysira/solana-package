#!/usr/bin/env python3
"""Kurtosis local-network acceptance; SIG is an observer, never an SVM oracle."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import threading
import time
import urllib.request

RPCS = {"jito": "http://val-bootstrap:8899", "agave": "http://val-joiner:8899",
        "firedancer": "http://val-firedancer:8899"}
AMOUNT = 1_000_000_000


class CheckFailed(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise CheckFailed(message)


def decode_rpc(data):
    response = json.loads(data)
    require(isinstance(response, dict) and "error" not in response and "result" in response,
            f"invalid RPC response: {response}")
    return response["result"]


def validate_votes(result, expected):
    require(isinstance(result, dict), "missing vote accounts")
    current = {v["nodePubkey"]: v for v in result["current"]}
    delinquent = {v["nodePubkey"] for v in result["delinquent"]}
    selected = {}
    for role, identity in expected.items():
        require(identity in current and identity not in delinquent, f"{role} absent or delinquent")
        v = current[identity]
        require(v["activatedStake"] > 0 and v["lastVote"] > 0 and v["rootSlot"] > 0,
                f"{role} lacks active stake/vote/root")
        selected[role] = {"lastVote": v["lastVote"], "rootSlot": v["rootSlot"],
                          "votePubkey": v["votePubkey"], "activatedStake": v["activatedStake"]}
    return selected


def validate_sig_peer(nodes, ip, identity=None):
    peers = [n for n in nodes if n.get("gossip", "").split(":")[0] == ip]
    require(len(peers) == 1, "SIG missing or ambiguous in peer gossip")
    peer = peers[0]
    require(identity is None or identity == peer["pubkey"], "SIG identity changed during observation")
    return peer["pubkey"]


def validate_transfer(tx, recipient, amount):
    require(isinstance(tx, dict) and tx.get("meta") is not None, "transaction unavailable")
    require(tx["meta"]["err"] is None, "transaction execution failed")
    keys = tx["transaction"]["message"]["accountKeys"]
    keys = [k["pubkey"] if isinstance(k, dict) else k for k in keys]
    require(recipient in keys, "recipient missing from transaction")
    index = keys.index(recipient)
    delta = tx["meta"]["postBalances"][index] - tx["meta"]["preBalances"][index]
    require(delta == amount, f"recipient delta {delta} != {amount}")
    return tx["slot"]


def validate_samples(samples, duration, minimum_growth):
    require(len(samples) >= 2 and samples[-1]["elapsed"] >= duration, "observation window incomplete")
    for endpoint in RPCS:
        require(samples[-1]["finalized"][endpoint] - samples[0]["finalized"][endpoint] >= minimum_growth,
                f"{endpoint} finalized slot growth below {minimum_growth}")
    checkpoint = samples[0]
    for sample in samples[1:]:
        if sample["elapsed"] - checkpoint["elapsed"] < 60:
            continue
        for role in RPCS:
            require(sample["votes"][role]["lastVote"] > checkpoint["votes"][role]["lastVote"],
                    f"{role} vote stalled")
            require(sample["votes"][role]["rootSlot"] > checkpoint["votes"][role]["rootSlot"],
                    f"{role} root stalled")
        checkpoint = sample


class Network:
    def __init__(self, out):
        self.out = Path(out)
        self.out.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.env = dict(line.split("=", 1) for line in Path("/data/meta.env").read_text().splitlines()
                        if line and not line.startswith("#"))
        self.identities = {r: self.env[k] for r, k in
                           [("jito", "BOOTSTRAP_IDENTITY"), ("agave", "JOINER_IDENTITY"),
                            ("firedancer", "FIREDANCER_IDENTITY")]}
        require(len(set(self.identities.values())) == 3, "duplicate validator identities")

    def record(self, name, data):
        with self.lock:
            with (self.out / name).open("a") as f:
                f.write(json.dumps(data, separators=(",", ":")) + "\n")

    def rpc(self, role, method, params=None):
        body = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}
        request = urllib.request.Request(RPCS[role], data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                raw = response.read()
            self.record("rpc.jsonl", {"at": time.time(), "role": role, "request": body,
                                     "response": json.loads(raw)})
            return decode_rpc(raw)
        except Exception as e:
            self.record("rpc-errors.jsonl", {"at": time.time(), "role": role, "request": body,
                                            "error": str(e)})
            raise

    def cli(self, *args):
        command = ["/opt/agave/bin/solana", "--url", RPCS["jito"], *args]
        proc = subprocess.run(command, capture_output=True, text=True, timeout=90)
        self.record("cli.jsonl", {"at": time.time(), "args": command, "code": proc.returncode,
                                 "stdout": proc.stdout, "stderr": proc.stderr})
        require(proc.returncode == 0, f"CLI failed: {proc.stderr[-1000:]}")
        return proc.stdout

    def send_transfer(self, recipient):
        result = json.loads(self.cli("--keypair", "/data/bootstrap-identity.json",
                                    "--commitment", "finalized", "transfer", recipient, "1",
                                    "--allow-unfunded-recipient", "--output", "json-compact"))
        require(bool(result.get("signature")), "transfer returned no signature")
        return result["signature"]

    def confirmed_transfer(self, signature, recipient):
        records = {}
        for role in ["jito", "agave"]:
            status = self.rpc(role, "getSignatureStatuses", [[signature], {"searchTransactionHistory": True}])["value"][0]
            require(status is not None and status["err"] is None
                    and status["confirmationStatus"] == "finalized", f"{role}: transfer not finalized")
            tx = self.rpc(role, "getTransaction", [signature, {"commitment": "finalized",
                          "encoding": "json", "maxSupportedTransactionVersion": 0}])
            slot = validate_transfer(tx, recipient, AMOUNT)
            require(signature in tx["transaction"]["signatures"], "wrong transaction returned")
            records[role] = {"slot": slot, "recipientDelta": AMOUNT}
        require(records["jito"]["slot"] == records["agave"]["slot"], "transaction slot mismatch")
        slot = records["jito"]["slot"]
        leader = self.rpc("jito", "getSlotLeaders", [slot, 1])[0]
        return {"signature": signature, "recipient": recipient, "lamports": AMOUNT,
                "slot": slot, "leader": leader, "observations": records}

    def wait(self, fn, timeout, label):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                result = fn()
                if result:
                    return result
            except Exception as e:
                last = str(e)
            time.sleep(2)
        raise CheckFailed(f"timeout waiting for {label}: {last}")

    def prepare_sig(self, snapshot_out):
        self.wait(lambda: self.rpc("jito", "getSlot", [{"commitment": "finalized"}]) > 0,
                  600, "finalized bootstrap")
        recipient_file = self.out / "primer-recipient-keypair.json"
        subprocess.run(["/opt/agave/bin/solana-keygen", "new", "--no-bip39-passphrase", "--silent",
                        "--force", "--outfile", str(recipient_file)], check=True, capture_output=True)
        recipient = subprocess.check_output(["/opt/agave/bin/solana-keygen", "pubkey",
                                             str(recipient_file)], text=True).strip()
        # The private key is unnecessary after deriving a public, unfunded recipient.
        recipient_file.unlink()
        signature = self.send_transfer(recipient)
        transfer = self.wait(lambda: self.confirmed_transfer(signature, recipient), 90, "primer transfer")
        minimum_slot = transfer["slot"]
        destination = Path(snapshot_out)
        destination.mkdir(parents=True, exist_ok=True)

        def download():
            highest = self.rpc("jito", "getHighestSnapshotSlot")["full"]
            if highest < minimum_slot:
                return None
            with urllib.request.urlopen(RPCS["jito"] + "/snapshot.tar.bz2", timeout=30) as response:
                filename = response.geturl().rsplit("/", 1)[-1]
                match = re.fullmatch(r"snapshot-(\d+)-[1-9A-HJ-NP-Za-km-z]+\.(?:tar\.zst|tar\.bz2)", filename)
                require(match is not None, "unexpected snapshot filename")
                slot = int(match.group(1))
                if slot < minimum_slot:
                    return None
                data = response.read(64 * 1024 * 1024 + 1)
                require(0 < len(data) <= 64 * 1024 * 1024, "snapshot exceeds local fixture budget")
                import hashlib
                (destination / filename).write_bytes(data)
                return {"filename": filename, "slot": slot, "sha256": hashlib.sha256(data).hexdigest(),
                        "bytes": len(data), "source": response.geturl()}
        snapshot = self.wait(download, 600, "full snapshot containing primer")
        result = {"genesisHash": self.rpc("jito", "getGenesisHash"),
                  "primer": transfer, "snapshot": snapshot}
        (self.out / "sig-bootstrap.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result), flush=True)

    def sample(self, started, sig_ip, sig_identity=None):
        nodes = self.rpc("jito", "getClusterNodes")
        known = {n["pubkey"]: n for n in nodes}
        for role, identity in self.identities.items():
            require(identity in known, f"{role} missing from peer gossip")
            require(known[identity]["shredVersion"] == int(self.env["SHRED_VERSION"]),
                    f"{role} shred version differs")
        sig_identity = validate_sig_peer(nodes, sig_ip, sig_identity)
        with urllib.request.urlopen("http://sig-observer:9110/metrics", timeout=5) as response:
            require(response.status == 200 and bool(response.read()), "SIG telemetry not alive")
        votes = validate_votes(self.rpc("jito", "getVoteAccounts"), self.identities)
        for role, key in [("jito", "BOOTSTRAP_VOTE"), ("agave", "JOINER_VOTE"),
                          ("firedancer", "FIREDANCER_VOTE")]:
            require(votes[role]["votePubkey"] == self.env[key], f"{role} vote identity differs")
        finalized = {r: self.rpc(r, "getSlot", [{"commitment": "finalized"}]) for r in RPCS}
        result = {"at": time.time(), "elapsed": time.monotonic() - started, "votes": votes,
                  "finalized": finalized, "sigIdentity": sig_identity, "gossip": nodes,
                  "sigTelemetryAlive": True}
        self.record("samples.jsonl", result)
        return result

    def verify_fd_blocks(self, start, end):
        available = set(self.rpc("jito", "getBlocks", [start, end, {"commitment": "finalized"}]))
        leaders = []
        for chunk in range(start, end + 1, 5000):
            leaders += self.rpc("jito", "getSlotLeaders", [chunk, min(5000, end - chunk + 1)])
        slots = [start + i for i, leader in enumerate(leaders)
                 if leader == self.identities["firedancer"] and start + i in available]
        require(len(slots) >= 3, f"only {len(slots)} finalized Firedancer leader slots")
        blocks = []
        for slot in slots[:3]:
            observations = {r: self.rpc(r, "getBlock", [slot, {"commitment": "finalized",
                            "transactionDetails": "none", "rewards": False,
                            "maxSupportedTransactionVersion": 0}]) for r in ["jito", "agave"]}
            require(all(isinstance(v, dict) for v in observations.values()), "missing Firedancer block")
            require(observations["jito"]["blockhash"] == observations["agave"]["blockhash"]
                    and observations["jito"]["parentSlot"] == observations["agave"]["parentSlot"],
                    "Firedancer block differs across nodes")
            blocks.append({"slot": slot, "observations": observations})
        return {"acceptedLeaderSlots": slots, "verifiedBlocks": blocks}

    def observe(self, duration, slots_target):
        require(duration >= 60, "observation_seconds must be at least 60")
        sig_ip = socket.gethostbyname("sig-observer")
        self.wait(lambda: self.sample(time.monotonic(), sig_ip), 900, "three voters and SIG")
        genesis = {r: self.rpc(r, "getGenesisHash") for r in RPCS}
        require(set(genesis.values()) == {self.env["GENESIS_HASH"]}, "genesis mismatch")
        versions = {r: self.rpc(r, "getVersion") for r in RPCS}
        started = time.monotonic()
        samples = [self.sample(started, sig_ip)]
        require(samples[0]["finalized"]["jito"] >= slots_target, "slot target not reached")
        transactions, transfer_errors = [], []
        stop = threading.Event()

        def transfers():
            while not stop.is_set():
                try:
                    signature = self.send_transfer(self.env["RECIPIENT"])
                    tx = self.wait(lambda: self.confirmed_transfer(signature, self.env["RECIPIENT"]),
                                   90, "cross-node finalized transfer")
                    transactions.append(tx)
                    self.record("transfers.jsonl", tx)
                except Exception as e:
                    transfer_errors.append(str(e))
                    self.record("transfer-errors.jsonl", {"at": time.time(), "error": str(e)})
                stop.wait(5)
        worker = threading.Thread(target=transfers, daemon=True)
        worker.start()
        try:
            while samples[-1]["elapsed"] < duration:
                stop.wait(max(0, started + len(samples) * 10 - time.monotonic()))
                sample = self.sample(started, sig_ip, samples[0]["sigIdentity"])
                samples.append(sample)
                print(json.dumps({"elapsed": round(sample["elapsed"]), "finalized": sample["finalized"],
                                  "fdVote": sample["votes"]["firedancer"]["lastVote"]}), flush=True)
            validate_samples(samples, duration, 20)
        finally:
            stop.set()
            worker.join(timeout=185)
        require(not worker.is_alive(), "transfer worker did not terminate")
        require(transactions, f"no verified transfers: {transfer_errors}")
        fd_transactions = [t for t in transactions if t["leader"] == self.identities["firedancer"]]
        require(fd_transactions, "no test transaction finalized in a Firedancer-produced block")
        last_slot = max(t["slot"] for t in transactions)
        self.wait(lambda: all(self.rpc(r, "getSlot", [{"commitment": "finalized"}]) >= last_slot
                              for r in RPCS), 120, "all clients root the final transfer")
        accounts = {r: self.rpc(r, "getAccountInfo", [self.env["RECIPIENT"],
                    {"commitment": "finalized", "encoding": "base64"}]) for r in RPCS}
        require(all(a.get("value") is not None and a["context"]["slot"] >= last_slot
                    for a in accounts.values()), "account observation predates transfer")
        balances = {r: a["value"]["lamports"] for r, a in accounts.items()}
        require(len(set(balances.values())) == 1, f"recipient account effects differ: {balances}")
        final = self.sample(started, sig_ip, samples[0]["sigIdentity"])
        blocks = self.verify_fd_blocks(samples[0]["finalized"]["jito"], final["finalized"]["jito"])
        return {"schemaVersion": 2, "result": "PASS",
                "verifiedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "topology": "three-voting-validators-plus-SIG-observer", "genesis": genesis,
                "versions": versions, "identities": self.identities, "observationSeconds": duration,
                "pollSeconds": 10, "sampleCount": len(samples), "firstSample": samples[0],
                "lastSample": final, "firedancerProduction": blocks,
                "transferCount": len(transactions), "firedancerTransactions": fd_transactions,
                "recipientAccounts": accounts, "transferErrors": transfer_errors,
                "sigObserver": {"evidenceLevel": "joined", "voting": False,
                                "identity": final["sigIdentity"], "serviceIp": sig_ip,
                                "continuousReplay": False, "transactionExecution": False},
                "evidenceFiles": ["rpc.jsonl", "samples.jsonl", "transfers.jsonl",
                                  "cli.jsonl", "sig-bootstrap.json"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["prepare-sig", "observe"])
    parser.add_argument("--out", default="/data/verification")
    parser.add_argument("--snapshot-out", default="/data/prepared-snapshot")
    parser.add_argument("--observation-seconds", type=int, default=600)
    parser.add_argument("--slots-target", type=int, default=20)
    args = parser.parse_args()
    network = Network(args.out)
    try:
        if args.command == "prepare-sig":
            network.prepare_sig(args.snapshot_out)
        else:
            result = network.observe(args.observation_seconds, args.slots_target)
            (network.out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({"result": "PASS", "summary": str(network.out / "summary.json")}), flush=True)
    except Exception as e:
        (network.out / "summary.json").write_text(json.dumps(
            {"result": "FAIL", "phase": args.command, "error": str(e),
             "at": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
        raise


if __name__ == "__main__":
    main()
