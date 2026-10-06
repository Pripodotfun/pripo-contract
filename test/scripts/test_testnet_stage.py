import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from monad_preflight import ProbeError, rpc
from deploy_testnet import create2_address, created_address, receipt_cost
from run_monad_fork import redact_output
from testnet_stage import key_address, testnet_env, wallet


class TestnetStageTest(unittest.TestCase):
    def test_create2_library_receipts_without_contract_address(self):
        self.assertEqual(create2_address("0x" + "0" * 40, "0" * 64, "00"),
                         "0x4d1a2e2bb4f88f0250f26ffff098b0b30b26bf38")
        factory = "0x4e59b44847b379578588920ca78fbf26c0b4956c"
        target = create2_address(factory, "0" * 64, "00")
        item = {"transactionType": "CREATE2", "contractAddress": target}
        tx = {"to": factory, "input": "0x" + "0" * 64 + "00"}
        self.assertEqual(created_address(item, tx, {"contractAddress": None}), target)
        with self.assertRaises(ProbeError):
            created_address(item, dict(tx, input="0x" + "0" * 64 + "01"), {})
        with self.assertRaises(ProbeError):
            created_address(item, dict(tx, to="0x" + "1" * 40), {})

    def test_receipt_cost_keeps_limit_execution_and_value_separate(self):
        tx = {"gas": hex(100_000), "value": hex(7)}
        receipt = {"status": "0x1", "transactionHash": "0xabc", "blockNumber": "0x12",
                   "gasUsed": hex(23_000), "effectiveGasPrice": hex(102_000_000_000)}
        result = receipt_cost(tx, receipt)
        self.assertEqual(result["gasLimit"], 100_000)
        self.assertEqual(result["receiptGasUsed"], 23_000)
        self.assertEqual(result["receiptFeeWei"], 23_000 * 102_000_000_000)
        self.assertEqual(result["valueWei"], 7)
        with self.assertRaises(ProbeError):
            receipt_cost(tx, dict(receipt, status="0x0"))
        key = "ab" * 32
        text = "0x" + key + " " + key.upper() + " " + str(int(key, 16))
        self.assertNotIn(key, redact_output(text, {"FUNDED_DEPLOYER_PRIVATE_KEY": "0x" + key}))
        self.assertNotIn(str(int(key, 16)), redact_output(text, {"FUNDED_DEPLOYER_PRIVATE_KEY": "0x" + key}))

    def test_public_address_derivation_and_invalid_signers(self):
        # Public unit vector, never a deployment credential.
        self.assertEqual(key_address("0x" + "0" * 63 + "1"),
                         "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf")
        for bad in ("", "0xPLACEHOLDER", "0x" + "0" * 64, "0x" + "f" * 64):
            with self.assertRaises(ProbeError):
                key_address(bad)
        self.assertEqual(wallet({"FUNDED_DEPLOYER_PRIVATE_KEY": "placeholder"}),
                         {"address": None, "signerConfigured": False})
        with patch("testnet_stage.key_address", return_value="0x" + "1" * 40):
            with self.assertRaisesRegex(ProbeError, "does not match"):
                wallet({"DEPLOYER": "0x" + "2" * 40})

    def test_rpc_alias_and_public_chain_rejection_before_any_other_probe(self):
        with patch("testnet_stage.load_env", return_value={"ALCHEMY_MONAD_TESTNET_RPC": "https://test.invalid"}):
            with patch("testnet_stage.rpc", return_value=hex(10143)):
                env, endpoint = testnet_env()
                self.assertEqual(env["MONAD_TESTNET_RPC"], endpoint)
            with patch("testnet_stage.rpc", return_value=hex(143)) as call:
                with self.assertRaisesRegex(ProbeError, "10143"):
                    testnet_env()
                self.assertEqual(call.call_count, 1)
        with patch("testnet_stage.load_env", return_value={}):
            with self.assertRaises(ProbeError):
                testnet_env()
        for method in ("eth_sendRawTransaction", "eth_sendTransaction", "evm_setAccountBalance"):
            with self.assertRaisesRegex(ProbeError, "read-only"):
                rpc("https://test.invalid", method, [])


if __name__ == "__main__":
    unittest.main()
