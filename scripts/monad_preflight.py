#!/usr/bin/env python3
"""Read-only Monad/Pyth preflight. Never logs credentials or submits transactions."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


class ProbeError(Exception):
    """Public diagnostic only: no remote response body, URL or authorization header."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProbeError(f"HTTP redirect rejected ({code})")


def load_env():
    values = {}
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            match = re.fullmatch(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*", line)
            if not match:
                continue
            key, value = match.groups()
            if value[:1] in ("'", '"') and value[-1:] == value[:1]:
                value = value[1:-1]
            else:
                value = value.split(" #", 1)[0].rstrip()
            values[key] = value
    values.update(os.environ)
    return values


def request_json(url, data=None, headers=None):
    body = None if data is None else json.dumps(data).encode()
    request = urllib.request.Request(url, body, headers or {})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise ProbeError(f"HTTP {exc.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ProbeError(f"Connection failed ({type(exc).__name__})") from None
    except (ValueError, UnicodeError):
        raise ProbeError("Invalid JSON response") from None


def rpc(url, method, params):
    allowed = {"eth_chainId", "eth_getBlockByNumber", "eth_getCode", "eth_call", "eth_getStorageAt"}
    if method not in allowed:
        raise ProbeError("Only read-only RPC methods are permitted")
    result = request_json(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                          {"Content-Type": "application/json"})
    if "error" in result:
        error = result["error"]
        # Keep only the numeric code; provider messages can echo credential-bearing URLs.
        raise ProbeError(f"RPC error {error.get('code')}")
    if result.get("result") is None:
        raise ProbeError("RPC returned no result")
    return result["result"]


def attempt(fn):
    try:
        return fn()
    except ProbeError as exc:
        return {"error": str(exc)}


def price(raw):
    if not isinstance(raw, str) or not re.fullmatch(r"0x[0-9a-fA-F]{256}", raw):
        raise ProbeError("Invalid Pyth price tuple")
    words = [bytes.fromhex(raw[2 + i * 64:2 + (i + 1) * 64]) for i in range(4)]
    return {"price": int.from_bytes(words[0], "big", signed=True),
            "conf": int.from_bytes(words[1], "big"),
            "expo": int.from_bytes(words[2], "big", signed=True),
            "publish_time": int.from_bytes(words[3], "big")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--block", type=int, help="Pin an explicit historical block (default: finalized)")
    parser.add_argument("--output", default="reports/monad/preflight.json")
    args = parser.parse_args()
    env = load_env()
    endpoint = env.get("ALCHEMY_MONAD_RPC", "")
    if not endpoint:
        raise ProbeError("Set ALCHEMY_MONAD_RPC in .env")
    cfg = json.loads((ROOT / "config/monad-mainnet.json").read_text())
    # Authorization may only be sent to the documented Pyth service, without following redirects.
    if cfg["hermes"] != "https://pyth.dourolabs.app/hermes":
        raise ProbeError("Unexpected Hermes endpoint; review authentication destination before changing it")
    key = env.get("PYTH_API_KEY")
    auth = {"Authorization": "Bearer " + key} if key else {}
    for feeds in cfg["equityCandidates"].values():
        for feed in feeds.values():
            if not re.fullmatch(r"0x[0-9a-fA-F]{64}", feed):
                raise ProbeError("Candidate feed must be exactly 32 bytes")
    chain = int(rpc(endpoint, "eth_chainId", []), 16)
    if chain != cfg["chainId"]:
        raise ProbeError(f"Expected Monad mainnet chain 143, received {chain}")
    header = rpc(endpoint, "eth_getBlockByNumber", [hex(args.block) if args.block else "finalized", False])
    block = header["number"]
    stamp = int(header["timestamp"], 16)
    report = {"observedAt": datetime.now(timezone.utc).isoformat(), "chainId": chain,
              "forkBlock": int(block, 16), "forkHash": header["hash"], "forkTimestamp": stamp,
              "forkUtc": datetime.fromtimestamp(stamp, timezone.utc).isoformat(),
              "sources": cfg["sources"], "contracts": {}, "feeds": {}}
    for name in ("pythCore", "legacyPythCore", "usdc"):
        address = cfg[name]
        code = bytes.fromhex(rpc(endpoint, "eth_getCode", [address, block])[2:])
        contract = {"address": address, "codeBytes": len(code), "codeSha256": hashlib.sha256(code).hexdigest()}
        if name == "usdc" and code:
            contract["decimals"] = int(rpc(endpoint, "eth_call", [{"to": address, "data": "0x313ce567"}, block]), 16)
        report["contracts"][name] = contract
    # A second historical state read tests this endpoint beyond the current finalized state.
    older = max(1, int(block, 16) - 100_000)
    report["archiveProbe"] = {"block": older, "decimals": attempt(lambda: int(rpc(endpoint, "eth_call", [
        {"to": cfg["usdc"], "data": "0x313ce567"}, hex(older)]), 16))}

    def inspect_ticker(ticker):
        feeds = cfg["equityCandidates"][ticker]
        metadata_url = cfg["hermes"] + "/v2/price_feeds?" + urllib.parse.urlencode({"asset_type": "equity", "query": ticker})
        metadata = attempt(lambda: request_json(metadata_url, headers=auth))
        result = {"metadata": metadata, "candidates": {}}
        for kind, feed in feeds.items():
            observed = {}
            for provider in ("pythCore", "legacyPythCore"):
                if report["contracts"][provider]["codeBytes"] == 0:
                    observed[provider] = {"error": "No contract code"}
                    continue
                observation = attempt(lambda: price(rpc(endpoint, "eth_call", [
                    {"to": cfg[provider], "data": "0x96834ad3" + feed[2:]}, block])))
                if "error" not in observation:
                    observation["ageAtForkSeconds"] = stamp - observation["publish_time"]
                observed[provider] = observation
            observed["feedId"] = feed
            if isinstance(metadata, list):
                observed["registryMatches"] = [m for m in metadata if m.get("id", "").removeprefix("0x") == feed[2:]]
            result["candidates"][kind] = observed
        return ticker, result

    with ThreadPoolExecutor(max_workers=3) as pool:
        for ticker, result in pool.map(inspect_ticker, cfg["equityCandidates"]):
            report["feeds"][ticker] = result
    if key:
        ids = [feed for feeds in cfg["equityCandidates"].values() for feed in feeds.values()]
        query = urllib.parse.urlencode([("ids[]", feed) for feed in ids] + [("encoding", "hex"), ("parsed", "true")])
        updates = attempt(lambda: request_json(cfg["hermes"] + "/v2/updates/price/latest?" + query,
                                               headers=auth))
        report["latestUpdates"] = updates
        now = datetime.now(timezone.utc)
        report["updatesObservedAt"] = now.isoformat()
        report["observedOnUtcWeekend"] = now.weekday() >= 5
        report["freshness"] = {}
        for observation in updates.get("parsed", []):
            p = observation["price"]
            raw, conf, published = int(p["price"]), int(p["conf"]), int(p["publish_time"])
            age = int(now.timestamp()) - published
            confidence_bps = (conf * 10_000 + raw - 1) // raw if raw > 0 else None
            report["freshness"][observation["id"]] = {
                "publishTime": published, "ageSeconds": age, "confidenceBpsCeil": confidence_bps,
                "withinThreeSecondAndOnePercentGate": raw > 0 and 0 <= age <= 3 and confidence_bps <= 100}
        # This later block can anchor signed-update verification without warping a fork's timestamp.
        if "error" not in updates:
            update_header = rpc(endpoint, "eth_getBlockByNumber", ["latest", False])
            report["updateFork"] = {"block": int(update_header["number"], 16), "hash": update_header["hash"],
                                    "timestamp": int(update_header["timestamp"], 16)}
    else:
        report["latestUpdates"] = {"error": "PYTH_API_KEY is missing; weekend freshness and signed verification pending"}
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Read-only preflight saved to {args.output}")
    print(f"Chain {chain}, pinned block {report['forkBlock']}, UTC {report['forkUtc']}")
    for name, contract in report["contracts"].items():
        print(f"{name}: {contract['address']}, code bytes {contract['codeBytes']}")
    print("Signed updates:", "captured" if "error" not in report["latestUpdates"] else report["latestUpdates"]["error"])


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
