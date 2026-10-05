import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from dry_run_deployment import creation_summary
from monad_preflight import ProbeError
from run_monad_fork import redact_output


class DeploymentRunnerTest(unittest.TestCase):
    def test_creation_report_rejects_partial_substituted_and_receipted_runs(self):
        addresses = ["0x" + format(i, "040x") for i in range(1, 20)]
        manifest = {"contracts": addresses}
        transactions = [{"contractAddress": addr, "transactionType": "CREATE", "contractName": str(i),
                         "transaction": {"gas": "0x123"}} for i, addr in enumerate(addresses)]
        broadcast = {"transactions": transactions, "receipts": []}
        self.assertEqual(len(creation_summary(manifest, broadcast)), 19)
        for bad in ({"transactions": transactions[:-1]},
                    {"transactions": transactions, "receipts": [{}]},
                    {"transactions": [transactions[0]] * 19}):
            with self.assertRaises(ProbeError):
                creation_summary(manifest, bad)
        transactions[0]["transactionType"] = "CALL"
        with self.assertRaises(ProbeError):
            creation_summary(manifest, broadcast)

    def test_redacts_both_networks_and_pyth_from_forge_errors(self):
        env = {"ALCHEMY_MONAD_RPC": "https://rpc.invalid/mainnet-long-secret?token=token-one",
               "MONAD_TESTNET_RPC": "https://user:password@rpc.invalid/testnet-long-secret?token=token-two",
               "PYTH_API_KEY": "pyth-secret"}
        text = " ".join(env.values()) + " mainnet-long-secret testnet-long-secret token-one token-two password pyth-secret"
        output = redact_output(text, env)
        for secret in ("long-secret", "token-one", "token-two", "password", "pyth-secret"):
            self.assertNotIn(secret, output)


if __name__ == "__main__":
    unittest.main()
