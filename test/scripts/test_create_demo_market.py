import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from create_demo_market import check_plan, expected_calls
from monad_preflight import ProbeError


class DemoMarketPlanTest(unittest.TestCase):
    def test_only_exact_mock_seed_and_creation_are_accepted(self):
        addresses = ["0x" + format(i, "040x") for i in range(1, 5)]
        manifest = dict(zip(("usdc", "factory", "nullAdapter", "deployer"), addresses))
        manifest.update(chainId=10143, mockCollateral=True)
        plan = {"transactions": [
            {"transactionType": "CALL", "transaction": {
                "from": manifest["deployer"], "to": target, "input": data, "value": "0x0"}}
            for target, data in expected_calls(manifest)]}
        check_plan(manifest, plan)
        for index, field, value in ((0, "to", addresses[2]), (0, "value", "0x1"),
                                    (0, "from", addresses[0]), (1, "input", "0x")):
            changed = copy.deepcopy(plan)
            changed["transactions"][index]["transaction"][field] = value
            with self.assertRaises(ProbeError):
                check_plan(manifest, changed)
        wrong_seed = copy.deepcopy(plan)
        wrong_seed["transactions"][0]["transaction"]["input"] = (
            wrong_seed["transactions"][0]["transaction"]["input"][:-64] + format(2_000 * 10**18, "064x"))
        for changed in (wrong_seed, {"transactions": plan["transactions"][:1]}):
            with self.assertRaises(ProbeError):
                check_plan(manifest, changed)
        for changed in (dict(manifest, chainId=143), dict(manifest, mockCollateral=False)):
            with self.assertRaises(ProbeError):
                check_plan(changed, plan)


if __name__ == "__main__":
    unittest.main()
