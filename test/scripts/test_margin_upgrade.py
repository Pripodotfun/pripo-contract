import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from margin_upgrade import check_plan, expected_calls
from monad_preflight import ProbeError


class MarginUpgradePlanTest(unittest.TestCase):
    def setUp(self):
        addresses = ["0x" + format(i, "040x") for i in range(1, 20)]
        self.m = dict(chainId=10143, mockCollateral=True, factory=addresses[0], vault=addresses[1],
                      deployer=addresses[2], usdc=addresses[3], nullAdapter=addresses[4], marketImplementation=addresses[5])
        self.u = dict(chainId=10143, mockCollateral=True, factory=self.m["factory"], vault=self.m["vault"],
                      deployer=self.m["deployer"], previousImplementation=self.m["marketImplementation"],
                      implementation=addresses[6], contracts=addresses[6:18], runtimeCodeHashes=["0x" + "ab" * 32] * 12)

    def plan(self, stage):
        return {"transactions": [{"transactionType": "CALL", "transaction": {"from": self.m["deployer"],
            "to": target, "input": data, "value": "0x0"}} for target, data in expected_calls(self.m, self.u, stage)]}

    def test_exact_governance_and_seed_calls_reject_extra_calls_mutations_and_wrong_chain(self):
        for stage in ("schedule", "activate", "create"):
            plan = self.plan(stage); check_plan(self.m, self.u, stage, plan)
            mutations = []
            for field, value in (("from", self.m["vault"]), ("to", self.m["deployer"]), ("value", "0x1"), ("input", "0xdeadbeef")):
                wrong = copy.deepcopy(plan); wrong["transactions"][-1]["transaction"][field] = value; mutations.append(wrong)
            wrong = copy.deepcopy(plan); wrong["transactions"].append(wrong["transactions"][0]); mutations.append(wrong)
            for wrong in mutations:
                with self.assertRaises(ProbeError): check_plan(self.m, self.u, stage, wrong)
            with self.assertRaises(ProbeError): check_plan(self.m, dict(self.u, chainId=143), stage, plan)
            with self.assertRaises(ProbeError): check_plan(self.m, dict(self.u, previousImplementation=self.m["vault"]), stage, plan)

    def test_deploy_requires_unique_manifest_addresses_and_no_calls(self):
        plan = {"transactions": [{"transactionType": "CREATE" if i == 0 else "CREATE2", "contractAddress": address,
            "transaction": {"from": self.m["deployer"], "value": "0x0"}} for i, address in enumerate(self.u["contracts"])]}
        check_plan(self.m, self.u, "deploy", plan)
        for index, field, value in ((0, "transactionType", "CALL"), (0, "contractAddress", self.m["vault"]),
                                    (1, "contractAddress", self.u["implementation"])):
            wrong = copy.deepcopy(plan); wrong["transactions"][index][field] = value
            with self.assertRaises(ProbeError): check_plan(self.m, self.u, "deploy", wrong)


if __name__ == "__main__": unittest.main()
