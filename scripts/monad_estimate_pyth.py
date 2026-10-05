#!/usr/bin/env python3
"""Estimate captured Pyth updates on Monad RPC without signing or submitting a transaction."""
import json
import re
import subprocess

from monad_preflight import ROOT, ProbeError, attempt, load_env, rpc


def calldata(signature, payloads):
    if not payloads or any(not re.fullmatch(r"(?:[0-9a-fA-F]{2})+", value) for value in payloads):
        raise ProbeError("Expected nonempty hex Hermes payloads")
    result = subprocess.run(["cast", "calldata", signature, "[" + ",".join("0x" + p for p in payloads) + "]"],
                            capture_output=True, text=True)
    if result.returncode:
        raise ProbeError("Cannot encode Pyth calldata with cast")
    return result.stdout.strip()


def main():
    env = load_env()
    endpoint = env.get("ALCHEMY_MONAD_RPC")
    if not endpoint:
        raise ProbeError("Set ALCHEMY_MONAD_RPC in .env")
    report = json.loads((ROOT / "reports/monad/preflight.json").read_text())
    cfg = json.loads((ROOT / "config/monad-mainnet.json").read_text())
    if "updateFork" not in report:
        raise ProbeError("Capture authenticated updates with monad_preflight.py first")
    anchor = report["updateFork"]
    block = hex(anchor["block"])
    if int(rpc(endpoint, "eth_chainId", []), 16) != 143:
        raise ProbeError("Expected Monad mainnet")
    if rpc(endpoint, "eth_getBlockByNumber", [block, False])["hash"] != anchor["hash"]:
        raise ProbeError("Pinned update block hash changed")
    captures = {cfg["controlFeed"]["feedId"]: report["controlUpdate"]}
    captures.update(report.get("equityUpdates", {}))
    results = {}
    for feed, capture in captures.items():
        update = capture["updates"]
        if "error" in update:
            results[feed] = {"error": update["error"]}
            continue
        if update["binary"]["encoding"] != "hex":
            raise ProbeError("Unexpected payload encoding")
        data = update["binary"]["data"]
        fee_call = {"to": cfg["pythCore"], "data": calldata("getUpdateFee(bytes[])", data)}
        fee = int(rpc(endpoint, "eth_call", [fee_call, block]), 16)
        tx = {"from": "0x000000000000000000000000000000000000bEEF", "to": cfg["pythCore"],
              "data": calldata("updatePriceFeeds(bytes[])", data), "value": hex(fee), "gas": hex(30_000_000)}
        estimate = attempt(lambda: int(rpc(endpoint, "eth_estimateGas", [tx, block]), 16))
        results[feed] = {"estimatedGas": estimate, "oracleUpdateFeeWei": fee,
                         "submittedGasLimit": None, "chargedGas": None, "chargedFeeWei": None}
        print(f"{feed}: estimated gas {estimate}, oracle fee {fee} wei; no transaction submitted")
    output = {"chainId": 143, "provider": cfg["pythCore"], "anchor": anchor,
              "scope": "RPC simulation of provider updates only, using an unfunded synthetic sender and no gas price",
              "results": results}
    (ROOT / "reports/monad/pyth-gas-estimates.json").write_text(json.dumps(output, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
