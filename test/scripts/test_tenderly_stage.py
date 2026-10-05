import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from monad_preflight import ProbeError
from run_monad_fork import redact_output
from tenderly_stage import alert_payloads, event_definitions, monad_support


class TenderlyStageTest(unittest.TestCase):
    def test_support_requires_mainnet_and_each_feature(self):
        row = {"chain_id": "143", "is_testnet": False, "supported_features": {
            "virtual_testnet": True, "monitoring": True, "simulator": True, "explorer": True}}
        self.assertEqual(monad_support([row]), row)
        for feature in row["supported_features"]:
            unsupported = copy.deepcopy(row)
            unsupported["supported_features"][feature] = False
            with self.assertRaises(ProbeError):
                monad_support([unsupported])
        for rows in ([], [row, row], [dict(row, is_testnet=True)]):
            with self.assertRaises(ProbeError):
                monad_support(rows)

    def test_alerts_bind_to_vault_proxy_and_each_clone_using_runtime_abi(self):
        definitions = event_definitions()
        self.assertEqual([item["signature"] for item in definitions], [
            "BadDebt(address,address,uint256,uint8)", "StatusChanged(address,uint8,uint8,uint64)",
            "DeficitChanged(address,uint256,uint256,uint8)", "ForcedSettlement(address,uint256,uint256,uint8)"])
        vault = "0x" + "11" * 20
        markets = ["0x" + pair * 20 for pair in ("22", "33", "44")]
        payloads = alert_payloads(definitions, "143", vault, markets, "channel-id")
        self.assertEqual(len(payloads), 10)
        for item in payloads:
            self.assertTrue(item["enabled"])
            self.assertEqual(item["expressions"][0]["expression"]["network_id"], "143")
            event = item["expressions"][1]["expression"]
            expected = [vault] if event["event_name"] == "DeficitChanged" else markets
            self.assertIn(event["address"], expected)
            self.assertNotIn("match_any", event)
        for bad_markets in ([], [vault], [markets[0], markets[0]], ["0x" + "00" * 20]):
            with self.assertRaises(ProbeError):
                alert_payloads(definitions, "143", vault, bad_markets, "channel-id")

    def test_tenderly_rpc_key_and_existing_signer_never_escape_redaction(self):
        env = {"TENDERLY_RPC": "https://virtual.monad.rpc.tenderly.co/secret-fork-access-token",
               "TENDERLY_ACCESS_KEY": "tenderly-private-key", "FUNDED_DEPLOYER_PRIVATE_KEY": "signer-secret",
               "ALCHEMY_MONAD_TESTNET_RPC": "https://rpc.invalid/secret-testnet-token"}
        text = " ".join(env.values()) + " secret-fork-access-token secret-testnet-token"
        output = redact_output(text, env)
        for secret in ("tenderly-private-key", "signer-secret", "secret-fork-access-token", "secret-testnet-token"):
            self.assertNotIn(secret, output)


if __name__ == "__main__":
    unittest.main()
