#!/usr/bin/env python3
"""Create a BTC/USD Pyth market on the recorded single-account Tenderly demo."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import re
import subprocess
import time
import urllib.parse

from deploy_testnet import keccak, receipt_cost
from deploy_tenderly import save
from mock_testnet import calldata
from monad_preflight import ROOT, ProbeError, request_json, rpc, price
from tenderly_demo import context, words
from tenderly_environment import SENDER

FOLDER = ROOT / "reports/deployment/tenderly-pyth-market"
RECORD = ROOT / "deployments/tenderly-demo.json"
SYMBOL = "BTC:USD"
FEED = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"
DEPTH, SEED, BOND = 2_000_000 * 10**18, 5_000 * 10**6, 500 * 10**6


def signed_price(env):
    query = urllib.parse.urlencode({"ids[]": FEED, "encoding": "hex", "parsed": "true"})
    result = request_json("https://pyth.dourolabs.app/hermes/v2/updates/price/latest?" + query,
                          headers={"Authorization": "Bearer " + env["PYTH_API_KEY"]})
    parsed = result.get("parsed", [])
    payloads = result.get("binary", {}).get("data", [])
    if (len(parsed) != 1 or "0x" + parsed[0]["id"].removeprefix("0x") != FEED
            or result.get("binary", {}).get("encoding") != "hex" or not payloads
            or any(not re.fullmatch(r"(?:[0-9a-fA-F]{2})+", p) for p in payloads)):
        raise ProbeError("Unexpected signed BTC payload")
    p = parsed[0]["price"]
    raw, conf, stamp = int(p["price"]), int(p["conf"]), int(p["publish_time"])
    if raw <= 0 or conf < 0 or conf * 100 > raw or not 0 <= time.time() - stamp <= 30:
        raise ProbeError("BTC observation is stale, future-dated or outside confidence gate")
    update = subprocess.check_output(["cast", "abi-encode", "f(bytes[])",
                                      "[" + ",".join("0x" + p for p in payloads) + "]"], text=True).strip()
    return result, update


class Demo:
    def __init__(self):
        self.env, self.url, self.proof = context()
        self.record = json.loads(RECORD.read_text())
        self.m = self.record["manifest"]
        if self.record["environment"] != self.proof or not self.record["demoOnly"]:
            raise ProbeError("Deployment does not belong to the authenticated demo instance")
        FOLDER.mkdir(parents=True, exist_ok=True)
        self.check_bindings()

    def w(self, target, signature, *args, block="latest"):
        return words(self.url, target, signature, *args, block=block)

    def check_bindings(self):
        m = self.m
        def code(pair):
            address, expected = pair
            if keccak(rpc(self.url, "eth_getCode", [address, "latest"])) != expected:
                raise ProbeError("Demo contract runtime changed")
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(code, [(m["contracts"][i], m["runtimeCodeHashes"][i]) for i in (1, 2, 4, 7)]))
        for target, signature, expected in ((m["vault"], "governor()", int(SENDER, 16)),
                (m["factory"], "vault()", int(m["vault"], 16)),
                (m["pythAdapter"], "pyth()", int(m["pythCore"], 16))):
            if self.w(target, signature) != [expected]:
                raise ProbeError("Unexpected demo role or dependency binding")

    def admin(self, method, params):
        if method not in ("eth_sendTransaction", "evm_setNextBlockTimestamp"):
            raise ProbeError("Unsupported demo mutation")
        result = request_json(self.url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                              {"Content-Type": "application/json"})
        if "error" in result or result.get("result") is None:
            raise ProbeError("Tenderly mutation failed; reconcile its journal before retrying")
        return result["result"]

    def clock(self, name, stamp):
        # Fork rehearsal only: no oracle storage, publish time or freshness guard is changed.
        before = rpc(self.url, "eth_getBlockByNumber", ["latest", False])
        record = {"environment": self.proof, "beforeBlock": int(before["number"], 16),
                  "beforeTimestamp": int(before["timestamp"], 16), "requestedTimestamp": stamp,
                  "wallClockTimestamp": int(time.time()), "status": "submitting"}
        path = FOLDER / (name + "-clock.json")
        if path.exists():
            raise ProbeError("Clock journal already exists; reconcile before retry")
        save(path, record)
        self.admin("evm_setNextBlockTimestamp", [hex(stamp)])
        after = rpc(self.url, "eth_getBlockByNumber", ["latest", False])
        if int(after["timestamp"], 16) != stamp:
            raise ProbeError("Virtual clock did not reach the requested timestamp")
        save(path, dict(record, status="verified", block=int(after["number"], 16)))

    def transaction(self, name, target, data, value=0, simulate=True):
        path = FOLDER / (name + ".json")
        if path.exists():
            old = json.loads(path.read_text())
            if (old["environment"] != self.proof or old["transaction"]["to"].lower() != target.lower()
                    or old["transaction"]["data"] != data or int(old["transaction"]["value"], 16) != value):
                raise ProbeError("Transaction journal differs from this request")
            if old["status"] == "verified":
                return old["receipt"]
            raise ProbeError("Unverified submission exists; reconcile before retrying")
        # Tenderly hashes unsigned envelopes without the impersonated sender. A distinct gas
        # limit keeps identical council calls from separate demo accounts from sharing a hash.
        tx = {"from": SENDER, "to": target, "data": data, "value": hex(value), "gas": hex(8_000_000 + int(SENDER, 16) % 1000)}
        if simulate:
            rpc(self.url, "eth_call", [tx, "pending"])
        record = {"environment": self.proof, "status": "submitting", "transaction": tx}
        save(path, record)
        txhash = self.admin("eth_sendTransaction", [tx])
        record.update(status="submitted", hash=txhash)
        save(path, record)
        for _ in range(10):
            try:
                receipt = rpc(self.url, "eth_getTransactionReceipt", [txhash])
                break
            except ProbeError:
                time.sleep(1)
        else:
            raise ProbeError("Receipt not available; reconcile submission")
        actual = rpc(self.url, "eth_getTransactionByHash", [txhash])
        if (actual["from"].lower() != SENDER.lower() or actual["to"].lower() != target.lower()
                or actual["input"] != data or int(actual["value"], 16) != value):
            raise ProbeError("Submitted call differs from journal")
        cost = receipt_cost(actual, receipt)
        header = rpc(self.url, "eth_getBlockByNumber", [receipt["blockNumber"], False])
        cost["timestamp"] = int(header["timestamp"], 16)
        save(path, dict(record, status="verified", receipt=cost))
        print(name + ": " + txhash, flush=True)
        return cost

    def empty_book(self):
        f = self.m["factory"]
        for i in range(self.w(f, "marketCount()")[0]):
            market = "0x" + format(self.w(f, "markets(uint256)", i)[0], "040x")
            if self.w(market, "positionCount()") != [0]:
                raise ProbeError("Clock rehearsal requires empty books")

    def prepare(self):
        self.empty_book()
        m, f, a = self.m, self.m["factory"], self.m["pythAdapter"]
        if self.w(f, "allowedAdapters(address)", a) != [1]:
            scheduled = self.transaction("schedule", f, calldata("scheduleAdapter(address)", a))
            ready = self.w(f, "adapterReadyAt(address)", a)[0]
            if ready != scheduled["timestamp"] + 86400:
                raise ProbeError("Unexpected governance delay")
            try:
                self.w(f, "activateAdapter(address)", a)
            except ProbeError:
                save(FOLDER / "early-activation.json", {"rejected": True, "readyAt": ready})
            else:
                raise ProbeError("Adapter activated before delay")
            try:
                self.clock("governance-delay", ready)
                self.transaction("activate", f, calldata("activateAdapter(address)", a))
            finally:
                self.clock("restore-wall-clock", int(time.time()))
        if self.w(a, "isSupported(bytes32)", FEED) != [1]:
            raise ProbeError("Real Pyth contract does not yet contain BTC")
        self.transaction("approve", m["usdc"], calldata("approve(address,uint256)", f, SEED + BOND))
        self.transaction("list", f, calldata("listFeed(address,bytes32)", a, FEED))
        print("BTC feed approved and listed; market insurance allowance prepared.", flush=True)

    def create(self):
        self.empty_book()
        m, f, a = self.m, self.m["factory"], self.m["pythAdapter"]
        if self.w(f, "marketForFeed(address,bytes32)", a, FEED) != [0]:
            raise ProbeError("BTC market already exists; use verify")
        payload, update = signed_price(self.env)
        fee = self.w(a, "updateFee(bytes)", update)[0]
        if fee > 10**15:
            raise ProbeError("Unexpected Pyth fee")
        data = calldata("createMarket((string,address,bytes32,uint256,uint256,uint256),bytes)",
                        f"({SYMBOL},{a},{FEED},1,{DEPTH},{SEED})", update)
        stamp = int(payload["parsed"][0]["price"]["publish_time"])
        save(FOLDER / "signed-update.json", {"fetchedAt": datetime.now(timezone.utc).isoformat(),
                                           "response": payload, "feeWei": fee})
        self.clock("price-simulation", stamp)
        rpc(self.url, "eth_call", [{"from": SENDER, "to": f, "data": data, "value": hex(fee),
                                   "gas": hex(8_000_000 + int(SENDER, 16) % 1000)}, "latest"])
        self.clock("price-submission", stamp)
        self.transaction("create", f, data, fee, simulate=False)
        self.verify()

    def verify(self):
        creation = json.loads((FOLDER / "create.json").read_text())
        if creation["status"] != "verified" or creation["environment"] != self.proof:
            raise ProbeError("Market submission has not been verified")
        m, cost = self.m, creation["receipt"]
        actual = rpc(self.url, "eth_getTransactionByHash", [creation["hash"]])
        receipt = rpc(self.url, "eth_getTransactionReceipt", [creation["hash"]])
        if receipt_cost(actual, receipt) != {k: v for k, v in cost.items() if k != "timestamp"}:
            raise ProbeError("Creation receipt differs from recorded evidence")
        block = hex(cost["block"])
        def w(target, signature, *args):
            return self.w(target, signature, *args, block=block)
        address = "0x" + format(w(m["factory"], "marketForFeed(address,bytes32)", m["pythAdapter"], FEED)[0], "040x")
        payload = json.loads((FOLDER / "signed-update.json").read_text())
        signed = payload["response"]["parsed"][0]["price"]
        observed = price(rpc(self.url, "eth_call", [{"to": m["pythCore"],
                         "data": calldata("getPriceUnsafe(bytes32)", FEED)}, block]))
        if any(observed[k] != int(signed[k]) for k in observed):
            raise ProbeError("Stored Pyth observation differs from signed payload")
        shift = observed["expo"] + 18
        wad = observed["price"] * 10**shift if shift >= 0 else observed["price"] // 10**(-shift)
        mark = DEPTH * 10**18 // (DEPTH * 10**18 // wad)
        age = cost["timestamp"] - observed["publish_time"]
        if not 0 <= age <= 3:
            raise ProbeError("Creation did not use a fresh observation")
        checks = [(m["factory"], "marketCount()", [], [2]),
                  (m["factory"], "predictAddress(string)", [SYMBOL], [int(address, 16)]),
                  (m["factory"], "allowedFeeds(address,bytes32)", [m["pythAdapter"], FEED], [1]),
                  (m["vault"], "protocolReserve()", [], [10_000 * 10**18]),
                  (m["vault"], "ledger(address)", [address], [0, 0, SEED * 10**12, 0, 0, 0]),
                  (m["vault"], "ledger(address)", [self.record["market"]["market"]],
                   [0, 0, 2_000 * 10**18, 0, 0, 0]),
                  (m["vault"], "requireOpenAllowed(address)", [address], []),
                  (m["usdc"], "balanceOf(address)", [m["vault"]], [17_000 * 10**6]),
                  (m["usdc"], "balanceOf(address)", [m["factory"]], [BOND]),
                  (m["usdc"], "allowance(address,address)", [SENDER, m["factory"]], [0]),
                  (address, "vault()", [], [int(m["vault"], 16)]),
                  (address, "feedId()", [], [int(FEED, 16)]),
                  (address, "externalIndex()", [], [1]),
                  (address, "markPrice()", [], [mark]), (address, "positionCount()", [], [0]),
                  (address, "status()", [], [0, cost["block"]]),
                  (address, "indexPrice()", [], [wad, cost["block"] - (age * 1000 + 299) // 300, 1])]
        def check(item):
            target, sig, args, expected = item
            if w(target, sig, *args) != expected:
                raise ProbeError("Market verification failed: " + sig)
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(check, checks))
        config = w(address, "config()")
        if config[0] != int(m["pythAdapter"], 16) or config[7] != 5:
            raise ProbeError("Unexpected market oracle or leverage cap")
        expected = "0x363d3d373d3d3d363d73" + m["marketImplementation"][2:] + "5af43d82803e903d91602b57fd5bf3"
        if rpc(self.url, "eth_getCode", [address, block]).lower() != expected.lower():
            raise ProbeError("Unexpected market implementation")
        result = {"network": self.record["network"], "demoOnly": True, "productionReady": False,
                  "environment": self.proof, "deployment": "tenderly-demo.json", "market": address,
                  "symbol": SYMBOL, "feed": "Crypto.BTC/USD", "feedId": FEED, "externalIndex": True,
                  "pythCore": m["pythCore"], "priceSource": m["pythAdapter"], "factory": m["factory"],
                  "vault": m["vault"], "usdc": m["usdc"], "creation": cost, "observation": observed,
                  "ageSecondsAtCreation": age, "initialPriceWad": wad, "initialMarkWad": mark, "depthWad": DEPTH,
                  "confidenceBpsCeil": (observed["conf"] * 10000 + observed["price"] - 1) // observed["price"],
                  "seedUsdc": 5000, "listingBondUsdc": 500, "reserveUsdc": 10000,
                  "vaultUsdc": 17000, "maxLeverageX": 5, "openingGatePassedAtCreation": True,
                  "signedUpdateVerifiedByPyth": True, "oracleFeeWei": payload["feeWei"],
                  "clockRehearsal": sorted([dict(json.loads(p.read_text()), operation=p.stem)
                                             for p in FOLDER.glob("*-clock.json")], key=lambda r: r["block"]),
                  "transactions": {name: json.loads((FOLDER / (name + ".json")).read_text())["receipt"]
                                   for name in ("schedule", "activate", "approve", "list", "create")},
                  "priceUpdates": "Opens require a fresh price. Opens and explicit refreshes accept signed Pyth pull updates; no background keeper is installed.",
                  "gasScope": "Tenderly receipt gas is not a Monad charged-gas measurement."}
        save(FOLDER / "verified.json", result)
        print(json.dumps({"market": address, "priceWad": wad, "ageSeconds": age, "verified": True}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "prepare", "create", "verify"))
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if args.action in ("prepare", "create") and not args.execute:
        raise ProbeError("Use --execute to submit the requested fork-only stage")
    demo = Demo()
    if args.action == "inspect":
        h = rpc(demo.url, "eth_getBlockByNumber", ["latest", False])
        print(json.dumps({"block": int(h["number"], 16), "timestamp": int(h["timestamp"], 16),
                          "pythSupportsBtc": demo.w(demo.m["pythAdapter"], "isSupported(bytes32)", FEED) == [1]}))
    else:
        getattr(demo, args.action)()


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
