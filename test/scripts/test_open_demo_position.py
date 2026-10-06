import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from mock_testnet import calldata
from monad_preflight import ProbeError
from open_demo_position import check_plan, expected_calls


class DemoPositionPlanTest(unittest.TestCase):
    def test_exact_deposit_direction_size_and_limit(self):
        addresses = ["0x" + format(i, "040x") for i in range(1, 6)]
        manifest = dict(zip(("usdc", "vault", "factory", "deployer"), addresses))
        manifest.update(chainId=10143, mockCollateral=True)
        market = {"chainId": 10143, "mockCollateral": True, "symbol": "PRIPO:DEMO",
                  "market": addresses[4], "vault": manifest["vault"], "factory": manifest["factory"]}
        plan = {"transactions": [
            {"transactionType": "CALL", "transaction": {
                "from": manifest["deployer"], "to": target, "input": data, "value": "0x0"}}
            for target, data in expected_calls(manifest, market)]}
        check_plan(manifest, market, plan)
        changes = [(0, "to", addresses[4]), (1, "value", "0x1"), (2, "from", addresses[0]),
                   (1, "input", calldata("deposit(uint256)", 100 * 10**18))]
        changes += [(2, "input", calldata("open(int256,uint256,bytes)", size, limit, "0x"))
                    for size, limit in ((-10**18, 101 * 10**18), (2 * 10**18, 101 * 10**18),
                                        (10**18, 2**256-1))]
        for index, field, value in changes:
            changed = copy.deepcopy(plan)
            changed["transactions"][index]["transaction"][field] = value
            with self.assertRaises(ProbeError):
                check_plan(manifest, market, changed)
        with self.assertRaises(ProbeError):
            check_plan(manifest, market, {"transactions": plan["transactions"][:2]})
        with self.assertRaises(ProbeError):
            check_plan(dict(manifest, chainId=143), market, plan)
        with self.assertRaises(ProbeError):
            check_plan(manifest, dict(market, mockCollateral=False), plan)


if __name__ == "__main__":
    unittest.main()
