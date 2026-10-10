import copy
from pathlib import Path
import sys
import json
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from monad_preflight import ProbeError
from tenderly_demo import CHAIN_ID, SENDER, check_plan, context, expected_calls, validate_domain


class TenderlyDemoTest(unittest.TestCase):
    def test_rpc_refresh_requires_the_exact_authenticated_instance(self):
        env = {"TENDERLY_ACCOUNT_SLUG": "a", "TENDERLY_PROJECT_SLUG": "p", "TENDERLY_RPC": "old"}
        record = {"status": "chain-domain-mismatch", "account": "a", "project": "p", "environmentId": "e",
                  "instanceId": "i", "vnetId": "v", "parent": {"chainId": 143, "block": 123}}
        vnet = {"id": "v", "sync_state_config": {"enabled": False}}
        with tempfile.TemporaryDirectory() as directory, \
                patch("tenderly_demo.FOLDER", Path(directory)), \
                patch("tenderly_demo.load_env", return_value=dict(env)), \
                patch("tenderly_demo.JOURNAL", Mock(read_text=lambda: json.dumps(record))), \
                patch("tenderly_demo.project_api", return_value={}), \
                patch("tenderly_demo.chain_domain", return_value={"rpcChainId": CHAIN_ID, "evmChainId": 1}), \
                patch("tenderly_demo.save_rpc") as save_rpc, \
                patch("tenderly_demo.environment_parts", return_value=({"id": "other"}, vnet, "new")) as parts:
            with self.assertRaises(ProbeError):
                context()
            save_rpc.assert_not_called()
            parts.return_value = ({"id": "i"}, vnet, "new")
            actual, endpoint, _ = context()
            self.assertEqual(endpoint, "new")
            self.assertEqual(actual["TENDERLY_RPC"], "new")
            save_rpc.assert_called_once_with("new")

    def test_demo_rejects_public_chains_and_unexpected_execution_domain(self):
        for evm in (1, CHAIN_ID):
            validate_domain({"rpcChainId": CHAIN_ID, "evmChainId": evm})
        for rpc_id, evm in ((1, 1), (143, 143), (10143, 10143), (CHAIN_ID, 143)):
            with self.assertRaises(ProbeError):
                validate_domain({"rpcChainId": rpc_id, "evmChainId": evm})

    def test_funding_plan_rejects_alternate_governor_recipient_or_value(self):
        manifest = {"chainId": CHAIN_ID, "rehearsalOnly": True,
                    **{r: SENDER for r in ("deployer", "governor", "guardian", "treasury")},
                    **{k: "0x" + format(i + 1, "040x") for i, k in enumerate(("vault", "factory", "usdc", "backstop"))}}
        plan = {"transactions": [{"transactionType": "CALL", "transaction": {
                "from": SENDER, "to": target, "input": data, "value": "0x0"}}
                for target, data in expected_calls(manifest, "fund")]}
        check_plan(manifest, plan, "fund")
        wrong = dict(manifest, governor=manifest["vault"])
        with self.assertRaises(ProbeError):
            check_plan(wrong, plan, "fund")
        for key, value in (("to", SENDER), ("input", "0x"), ("value", "0x1")):
            wrong = copy.deepcopy(plan)
            wrong["transactions"][0]["transaction"][key] = value
            with self.assertRaises(ProbeError):
                check_plan(manifest, wrong, "fund")


if __name__ == "__main__":
    unittest.main()
