import contextlib
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import monad_preflight as probe


class PreflightTest(unittest.TestCase):
    def test_client_identity_and_redirect_rejection(self):
        with patch.object(probe.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(b"{}")
            probe.request_json("https://pyth.dourolabs.app/hermes/test", headers={"Authorization": "Bearer sample-key"})
            req = opener.return_value.open.call_args.args[0]
            self.assertEqual(req.get_header("User-agent"), "pripo-integration/1.0")
            self.assertEqual(req.get_header("Authorization"), "Bearer sample-key")
        with self.assertRaisesRegex(probe.ProbeError, "redirect rejected"):
            probe.NoRedirect().redirect_request(None, None, 302, "", {}, "https://unrelated.invalid")

    def test_http_errors_do_not_echo_credentials_or_response_bodies(self):
        cases = [
            (403, b'Not entitled: sample-key requires ["pyth-indices"]', "HTTP 403: not entitled to pyth-indices"),
            (403, b"Not entitled: sample-key equity", "HTTP 403: not entitled to requested asset/feed"),
            (403, b'{"error_name":"browser_signature_banned","secret":"sample-key"}', "HTTP 403: client signature rejected"),
            (401, b"sample-key", "HTTP 401"),
        ]
        for status, body, expected in cases:
            with self.subTest(status=status, expected=expected), patch.object(probe.urllib.request, "build_opener") as opener:
                opener.return_value.open.side_effect = urllib.error.HTTPError(
                    "https://service.invalid/sample-key", status, "sample-key", {}, io.BytesIO(body))
                with self.assertRaises(probe.ProbeError) as error:
                    probe.request_json("https://service.invalid")
                self.assertEqual(str(error.exception), expected)

    def test_freshness_uses_price_time_and_confidence_ceiling(self):
        now = datetime(2026, 10, 4, 21, 33, 48, tzinfo=timezone.utc)
        stamp = int(now.timestamp())
        def capture(published, conf):
            return {"parsed": [{"id": "feed", "price": {"price": "100000", "conf": str(conf), "publish_time": published},
                                "metadata": {"proof_available_time": stamp}}]}
        current = probe.freshness(capture(stamp, 101), now)["feed"]
        self.assertEqual(current["confidenceBpsCeil"], 11)
        self.assertTrue(current["withinThreeSecondAndOnePercentGate"])
        for data in (capture(stamp - 164029, 10), capture(stamp + 1, 10), capture(stamp, 1001)):
            self.assertFalse(probe.freshness(data, now)["feed"]["withinThreeSecondAndOnePercentGate"])

    def test_denied_feed_does_not_discard_an_entitled_capture(self):
        cfg = json.loads((probe.ROOT / "config/monad-mainnet.json").read_text())
        entitled = {cfg["equityCandidates"]["TSLA"]["us"], cfg["controlFeed"]["feedId"]}
        def rpc(_, method, params):
            if method == "eth_chainId": return "0x8f"
            if method == "eth_getBlockByNumber": return {"number": "0x64", "timestamp": "0x6a000003", "hash": "0x" + "ab" * 32}
            if method == "eth_getCode": return "0x60"
            if method == "eth_call" and params[0]["data"] == "0x313ce567": return "0x6"
            raise probe.ProbeError("RPC error 3")
        def request(url, headers):
            self.assertTrue(url.startswith("https://pyth.dourolabs.app/hermes/"))
            self.assertEqual(headers, {"Authorization": "Bearer sample-key"})
            if "/price_feeds?" in url: return []
            feed = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["ids[]"][0]
            if feed not in entitled: raise probe.ProbeError("HTTP 403: not entitled to requested asset/feed")
            return {"parsed": [{"id": feed[2:], "price": {"price": "1", "conf": "0", "publish_time": 1}}],
                    "binary": {"encoding": "hex", "data": ["abcd"]}}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            (root / "config/monad-mainnet.json").write_text(json.dumps(cfg))
            with patch.object(probe, "ROOT", root), patch.object(probe, "load_env", return_value={
                "ALCHEMY_MONAD_RPC": "https://rpc.invalid/sample-key", "PYTH_API_KEY": "sample-key"
            }), patch.object(probe, "rpc", side_effect=rpc), patch.object(probe, "request_json", side_effect=request), \
                    patch.object(sys, "argv", ["preflight"]), contextlib.redirect_stdout(io.StringIO()) as output:
                probe.main()
            report = json.loads((root / "reports/monad/preflight.json").read_text())
            self.assertEqual(report["equityCaptures"], 1)
            self.assertIn("binary", report["controlUpdate"]["updates"])
            self.assertEqual(report["updateFork"]["block"], 100)
            self.assertNotIn("sample-key", json.dumps(report) + output.getvalue())


if __name__ == "__main__":
    unittest.main()
