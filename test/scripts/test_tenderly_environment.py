import copy
import io
import json
from pathlib import Path
import sys
import unittest
import urllib.error
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from monad_preflight import ProbeError
from tenderly_environment import CHAIN_ID, admin_rpc, create_payload, environment_parts, require_chain_domain
from tenderly_stage import ProjectAPIError, project_api, project_status


class TenderlyEnvironmentTest(unittest.TestCase):
    def test_api_validation_errors_redact_credentials_and_rpc_urls(self):
        env = {"TENDERLY_ACCOUNT_SLUG": "account", "TENDERLY_PROJECT_SLUG": "project", "TENDERLY_ACCESS_KEY": "secret"}
        error = urllib.error.HTTPError("https://api.tenderly.co", 400, "invalid", {},
                                      io.BytesIO(b'{"message":"secret https://virtual.monad.rpc.tenderly.co/new-private-rpc"}'))
        with patch("tenderly_stage.urllib.request.build_opener") as opener:
            opener.return_value.open.side_effect = error
            with self.assertRaises(ProjectAPIError) as caught:
                project_api(env, "/environments", public=True, data={})
        self.assertEqual(caught.exception.status, 400)
        self.assertNotIn("secret", str(caught.exception))
        self.assertNotIn("new-private-rpc", str(caught.exception))

    def test_project_metadata_permission_is_separate_and_admin_urls_are_not_reported(self):
        env = {"TENDERLY_ACCOUNT_SLUG": "account", "TENDERLY_PROJECT_SLUG": "project", "TENDERLY_ACCESS_KEY": "secret"}
        item = {"id": "env", "slug": "demo", "active_instance": {
            "id": "instance", "vnets": [{"rpcs": [{"url": "https://private-rpc-secret"}]}]}}
        with patch("tenderly_stage.project_api", side_effect=[ProbeError("HTTP 403"), [item]]):
            report = project_status(env)
        self.assertTrue(report["environmentAccess"])
        self.assertEqual(report["projectMetadataError"], "HTTP 403")
        self.assertNotIn("secret", json.dumps(report))
        with patch("tenderly_stage.project_api", side_effect=[{}, ProbeError("HTTP 403")]):
            with self.assertRaises(ProbeError):
                project_status(env)

    def test_fork_metadata_must_match_isolated_chain_and_exact_parent(self):
        payload = create_payload({"number": "0x1234"})
        self.assertEqual(payload["network_configs"][0]["network_id"], "143")
        self.assertEqual(payload["network_configs"][0]["explorer_config"],
                         {"enabled": False, "contract_verification_visibility": "abi"})
        self.assertEqual(payload["network_configs"][0]["chain_config_overrides"]["chain_id"], str(CHAIN_ID))
        record = {"request": payload, "parent": {"block": 0x1234}}
        vnet = {"fork_config": {"network_id": 143, "block_number": "0x1234"},
                "virtual_network_config": {"chain_config": {"chain_id": CHAIN_ID}},
                "rpcs": [{"name": "Admin RPC", "url": "https://virtual.monad.rpc.tenderly.co/private"}]}
        result = {"slug": payload["slug"], "active_instance": {"id": "instance", "vnets": [vnet]}}
        self.assertEqual(environment_parts(result, record)[1], vnet)
        for path, value in (("network_id", 1), ("block_number", "0x1235")):
            wrong = copy.deepcopy(result)
            wrong["active_instance"]["vnets"][0]["fork_config"][path] = value
            with self.assertRaises(ProbeError):
                environment_parts(wrong, record)
        wrong = copy.deepcopy(result)
        wrong["active_instance"]["vnets"][0]["virtual_network_config"]["chain_config"]["chain_id"] = 143
        with self.assertRaises(ProbeError):
            environment_parts(wrong, record)
        for endpoint in ("https://rpc.monad.xyz", "https://virtual.monad.rpc.tenderly.co.evil.test/key", "http://virtual.monad.rpc.tenderly.co/key"):
            wrong = copy.deepcopy(result)
            wrong["active_instance"]["vnets"][0]["rpcs"][0]["url"] = endpoint
            with self.assertRaises(ProbeError):
                environment_parts(wrong, record)

    def test_admin_mutations_reject_mainnet_before_submission(self):
        with patch("tenderly_environment.rpc", return_value=hex(143)), patch("tenderly_environment.request_json") as send:
            with self.assertRaises(ProbeError):
                admin_rpc("https://rpc.invalid", "eth_sendTransaction", [])
            send.assert_not_called()

    def test_evm_domain_mismatch_rejects_mutation_even_with_correct_rpc_id(self):
        with patch("tenderly_environment.rpc", side_effect=[hex(CHAIN_ID), hex(CHAIN_ID), hex(1)]), \
                patch("tenderly_environment.request_json") as send:
            with self.assertRaises(ProbeError):
                admin_rpc("https://rpc.invalid", "eth_sendTransaction", [])
            send.assert_not_called()

    def test_matching_evm_and_rpc_domains_are_required(self):
        with patch("tenderly_environment.rpc", side_effect=[hex(CHAIN_ID), hex(CHAIN_ID)]):
            require_chain_domain("https://rpc.invalid")
        with patch("tenderly_environment.rpc", side_effect=[hex(CHAIN_ID), hex(143)]):
            with self.assertRaises(ProbeError):
                require_chain_domain("https://rpc.invalid")


if __name__ == "__main__":
    unittest.main()
