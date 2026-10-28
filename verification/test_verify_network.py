import copy
import unittest
from unittest import mock
from verify_network import Network
from verify_network import CheckFailed, decode_rpc, validate_votes, validate_sig_peer, validate_transfer, validate_samples


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.expected = {"jito": "j", "agave": "a", "firedancer": "f"}
        self.votes = {"current": [{"nodePubkey": k, "votePubkey": k+"v",
                       "activatedStake": 100, "lastVote": 40, "rootSlot": 8}
                      for k in self.expected.values()], "delinquent": []}

    def test_missing_or_invalid_json_is_not_success(self):
        for data in ["", "null", "{}", '{"error":{"code":-1}}']:
            with self.subTest(data=data), self.assertRaises((ValueError, CheckFailed)):
                decode_rpc(data)

    def test_all_three_voters_required(self):
        self.assertEqual(len(validate_votes(self.votes, self.expected)), 3)
        self.votes["current"].pop()
        with self.assertRaises(CheckFailed):
            validate_votes(self.votes, self.expected)

    def test_delinquent_validator_rejected(self):
        self.votes["delinquent"].append(self.votes["current"][-1])
        with self.assertRaises(CheckFailed):
            validate_votes(self.votes, self.expected)

    def test_zero_root_rejected(self):
        self.votes["current"][2]["rootSlot"] = 0
        with self.assertRaises(CheckFailed):
            validate_votes(self.votes, self.expected)

    def test_sig_gossip_identity(self):
        nodes = [{"pubkey": "sig", "gossip": "10.0.0.4:8001"}]
        self.assertEqual(validate_sig_peer(nodes, "10.0.0.4"), "sig")
        for ip, key in [("10.0.0.5", None), ("10.0.0.4", "other")]:
            with self.assertRaises(CheckFailed):
                validate_sig_peer(nodes, ip, key)

    def test_existing_balance_does_not_prove_transfer(self):
        tx = {"slot": 10, "transaction": {"message": {"accountKeys": ["recipient"]}},
              "meta": {"err": None, "preBalances": [1000000000], "postBalances": [1000000000]}}
        with self.assertRaises(CheckFailed):
            validate_transfer(tx, "recipient", 1000000000)
        tx["meta"]["postBalances"][0] += 1000000000
        self.assertEqual(validate_transfer(tx, "recipient", 1000000000), 10)
        tx["meta"]["err"] = {"InstructionError": [0, "InvalidArgument"]}
        with self.assertRaises(CheckFailed):
            validate_transfer(tx, "recipient", 1000000000)

    def test_unfinalized_signature_is_rejected(self):
        network = Network.__new__(Network)
        for status in [None, {"err": None, "confirmationStatus": "confirmed"},
                       {"err": "failed", "confirmationStatus": "finalized"}]:
            network.rpc = lambda *a: {"value": [status]}
            with self.assertRaises(CheckFailed):
                network.confirmed_transfer("signature", "recipient")

    def test_exited_sig_is_rejected_even_with_stale_gossip(self):
        network = Network.__new__(Network)
        network.identities = self.expected
        network.env = {"SHRED_VERSION": "123"}
        nodes = [{"pubkey": k, "shredVersion": 123, "gossip": "10.0.0.1:8001"}
                 for k in self.expected.values()]
        nodes.append({"pubkey": "sig", "gossip": "10.0.0.4:8001"})
        network.rpc = lambda *a: nodes
        with mock.patch("urllib.request.urlopen", side_effect=ConnectionRefusedError):
            with self.assertRaises(ConnectionRefusedError):
                network.sample(0, "10.0.0.4")

    def test_stalled_votes_roots_and_finality(self):
        start = {"elapsed": 0, "finalized": {r: 100 for r in self.expected},
                 "votes": validate_votes(self.votes, self.expected)}
        end = copy.deepcopy(start)
        end["elapsed"] = 600
        end["finalized"] = {r: 200 for r in self.expected}
        for vote in end["votes"].values():
            vote["lastVote"] += 100
            vote["rootSlot"] += 100
        validate_samples([start, end], 600, 20)
        for field in ["lastVote", "rootSlot"]:
            stalled = copy.deepcopy(end)
            stalled["votes"]["firedancer"][field] = start["votes"]["firedancer"][field]
            with self.assertRaises(CheckFailed):
                validate_samples([start, stalled], 600, 20)
        end["finalized"]["firedancer"] = 100
        with self.assertRaises(CheckFailed):
            validate_samples([start, end], 600, 20)


if __name__ == "__main__":
    unittest.main()
