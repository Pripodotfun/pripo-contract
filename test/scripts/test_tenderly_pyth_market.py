import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from monad_preflight import ProbeError
from tenderly_pyth_market import Demo, FEED, signed_price


class TenderlyPythMarketTest(unittest.TestCase):
    def test_rejects_wrong_feed_stale_future_or_wide_confidence_before_encoding(self):
        base = {"parsed": [{"id": FEED[2:], "price": {
            "price": "6000000000000", "conf": "10000", "expo": -8, "publish_time": 1000}}],
            "binary": {"encoding": "hex", "data": ["aabb"]}}
        bad = []
        for key, value in (("publish_time", 900), ("publish_time", 1002), ("conf", "60000000001"), ("price", "0")):
            p = copy.deepcopy(base)
            p["parsed"][0]["price"][key] = value
            bad.append(p)
        p = copy.deepcopy(base)
        p["parsed"][0]["id"] = "00" * 32
        bad.append(p)
        for payload in bad:
            with patch("tenderly_pyth_market.request_json", return_value=payload), \
                    patch("tenderly_pyth_market.time.time", return_value=1001), \
                    patch("tenderly_pyth_market.subprocess.check_output") as encode:
                with self.assertRaises(ProbeError):
                    signed_price({"PYTH_API_KEY": "test"})
                encode.assert_not_called()

    def test_ambiguous_submission_cannot_be_replayed(self):
        demo = object.__new__(Demo)
        demo.proof = {"instanceId": "expected"}
        with tempfile.TemporaryDirectory() as folder, patch("tenderly_pyth_market.FOLDER", Path(folder)), \
                patch.object(demo, "admin") as send:
            record = {"environment": demo.proof, "status": "submitted", "transaction": {
                "to": "0x1234", "data": "0xaaaa", "value": "0x1"}}
            (Path(folder) / "create.json").write_text(json.dumps(record))
            with self.assertRaises(ProbeError):
                demo.transaction("create", "0x1234", "0xaaaa", 1)
            send.assert_not_called()

    def test_clock_changes_reject_nonempty_book(self):
        demo = object.__new__(Demo)
        demo.m = {"factory": "factory"}
        with patch.object(demo, "w", side_effect=[[1], [123], [1]]), patch.object(demo, "clock") as clock:
            with self.assertRaises(ProbeError):
                demo.empty_book()
            clock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
