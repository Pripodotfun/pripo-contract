import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from deploy_tenderly import context
from monad_preflight import ProbeError


class HostedDeploymentGuardTest(unittest.TestCase):
    def test_changed_instance_rpc_chain_or_sync_is_rejected(self):
        env = {"TENDERLY_ACCOUNT_SLUG": "a", "TENDERLY_PROJECT_SLUG": "p", "TENDERLY_RPC": "private"}
        record = {"status": "verified", "account": "a", "project": "p", "environmentId": "e",
                  "instanceId": "i", "vnetId": "v"}
        cases = [({"id": "other"}, {"id": "v", "sync_state_config": {"enabled": False}}, "private", 999143),
                 ({"id": "i"}, {"id": "other", "sync_state_config": {"enabled": False}}, "private", 999143),
                 ({"id": "i"}, {"id": "v", "sync_state_config": {"enabled": True}}, "private", 999143),
                 ({"id": "i"}, {"id": "v", "sync_state_config": {"enabled": False}}, "other", 999143),
                 ({"id": "i"}, {"id": "v", "sync_state_config": {"enabled": False}}, "private", 143)]
        for instance, vnet, endpoint, chain in cases:
            with self.subTest(instance=instance, vnet=vnet, endpoint=endpoint, chain=chain):
                with patch("deploy_tenderly.load_env", return_value=env), \
                        patch("deploy_tenderly.JOURNAL", Mock(read_text=lambda: json.dumps(record))), \
                        patch("deploy_tenderly.project_api", return_value={}), \
                        patch("deploy_tenderly.environment_parts", return_value=(instance, vnet, endpoint)), \
                        patch("deploy_tenderly.rpc", return_value=hex(chain)):
                    with self.assertRaises(ProbeError):
                        context()


if __name__ == "__main__":
    unittest.main()
