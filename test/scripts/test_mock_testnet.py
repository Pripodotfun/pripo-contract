import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from mock_testnet import check_plan, expected_calls
from monad_preflight import ProbeError


class MockTestnetPlanTest(unittest.TestCase):
    def test_exact_reserve_funding_bundle_and_reused_deployment(self):
        addresses = ["0x" + format(i, "040x") for i in range(1, 9)]
        token, vault, backstop, sweeper, factory, adapter, sender, old_vault = addresses
        manifest = {"chainId": 10143, "mockCollateral": True, "usdc": token, "vault": vault,
                    "factory": factory, "backstop": backstop, "pythAdapter": adapter, "deployer": sender,
                    "createdContracts": [token, vault, backstop, sweeper, factory]}
        creations = [{"transactionType": "CREATE", "contractAddress": address,
                      "transaction": {"from": sender, "value": "0x0"}} for address in manifest["createdContracts"]]
        calls = [{"transactionType": "CALL", "transaction": {"from": sender, "to": to, "input": data, "value": "0x0"}}
                 for to, data in expected_calls(manifest, "deploy")]
        plan = {"transactions": creations + calls}
        check_plan(manifest, plan, "deploy")
        mutations = []
        wrong = copy.deepcopy(plan)
        wrong["transactions"][-1]["transaction"]["to"] = old_vault
        mutations.append(wrong)
        wrong = copy.deepcopy(plan)
        wrong["transactions"][-1]["transaction"]["input"] = calls[-1]["transaction"]["input"][:-64] + format(10_000, "064x")
        mutations.append(wrong)
        wrong = copy.deepcopy(plan)
        wrong["transactions"][-1]["transaction"]["value"] = "0x1"
        mutations.append(wrong)
        mutations.append({"transactions": plan["transactions"][:-1]})
        for wrong in mutations:
            with self.assertRaises(ProbeError):
                check_plan(manifest, wrong, "deploy")
        with self.assertRaises(ProbeError):
            check_plan(dict(manifest, mockCollateral=False), plan, "deploy")
        with self.assertRaises(ProbeError):
            check_plan(dict(manifest, chainId=143), plan, "deploy")


if __name__ == "__main__":
    unittest.main()
