#!/usr/bin/env python3
"""Check Monad testnet dependencies and simulate deployment. Never signs or broadcasts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess
import urllib.parse

from dry_run_deployment import creation_summary
from monad_estimate_pyth import calldata
from monad_preflight import ROOT, ProbeError, attempt, freshness, load_env, request_json, rpc
from run_monad_fork import redact_output

FOLDER = ROOT / "reports/deployment"
SYNTHETIC = "0x000000000000000000000000000000000000bEEF"


def public_address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value or "") or int(value, 16) == 0:
        raise ProbeError("Expected a nonzero public address")
    return value


def key_address(value):
    """Feed the key through OpenSSL stdin; only its public key goes into cast's arguments."""
    key = value.removeprefix("0x")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", key):
        raise ProbeError("FUNDED_DEPLOYER_PRIVATE_KEY is absent or a placeholder")
    scalar = int(key, 16)
    if not 0 < scalar < 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141:
        raise ProbeError("Invalid deployer signing scalar")
    der = bytes.fromhex("302e0201010420" + key + "a00706052b8104000a")
    result = subprocess.run(["openssl", "ec", "-inform", "DER", "-pubout", "-outform", "DER"],
                            input=der, capture_output=True)
    if result.returncode or len(result.stdout) != 88 or result.stdout[-65] != 4:
        raise ProbeError("Cannot derive deployer public key")
    digest = subprocess.check_output(["cast", "keccak", "0x" + result.stdout[-64:].hex()], text=True).strip()
    return public_address("0x" + digest[-40:])


def wallet(env):
    derived = attempt(lambda: key_address(env.get("FUNDED_DEPLOYER_PRIVATE_KEY", "")))
    supplied = env.get("DEPLOYER")
    if supplied:
        supplied = public_address(supplied)
        if isinstance(derived, str) and derived.lower() != supplied.lower():
            raise ProbeError("DEPLOYER does not match the configured signing key")
    return {"address": supplied or (derived if isinstance(derived, str) else None),
            "signerConfigured": isinstance(derived, str)}


def testnet_env():
    env = load_env()
    endpoint = env.get("MONAD_TESTNET_RPC") or env.get("ALCHEMY_MONAD_TESTNET_RPC")
    if not endpoint:
        raise ProbeError("Set MONAD_TESTNET_RPC or ALCHEMY_MONAD_TESTNET_RPC")
    env["MONAD_TESTNET_RPC"] = endpoint
    if int(rpc(endpoint, "eth_chainId", []), 16) != 10143:
        raise ProbeError("Expected Monad testnet chain 10143")
    return env, endpoint


def preflight(env, endpoint):
    cfg = json.loads((ROOT / "config/monad-testnet.json").read_text())
    header = rpc(endpoint, "eth_getBlockByNumber", ["latest", False])
    block = header["number"]
    report = {"checkedAt": datetime.now(timezone.utc).isoformat(), "chainId": 10143, "broadcast": False,
              "block": int(block, 16), "hash": header["hash"], "timestamp": int(header["timestamp"], 16),
              "sources": cfg["sources"], "contracts": {}, "wallet": wallet(env)}
    for name in ("usdc", "pythCore"):
        code = bytes.fromhex(rpc(endpoint, "eth_getCode", [cfg[name], block])[2:])
        if not code:
            raise ProbeError(f"Missing official testnet {name} code")
        report["contracts"][name] = {"address": cfg[name], "codeBytes": len(code),
                                      "codeSha256": hashlib.sha256(code).hexdigest()}
    decimals = int(rpc(endpoint, "eth_call", [{"to": cfg["usdc"], "data": "0x313ce567"}, block]), 16)
    if decimals != 6:
        raise ProbeError("Official test USDC must have six decimals")
    report["contracts"]["usdc"]["decimals"] = decimals
    report["gasPriceWei"] = int(rpc(endpoint, "eth_gasPrice", []), 16)
    sender = report["wallet"]["address"]
    if sender:
        report["wallet"]["monWei"] = int(rpc(endpoint, "eth_getBalance", [sender, block]), 16)
        data = "0x70a08231" + sender[2:].rjust(64, "0")
        report["wallet"]["usdcUnits"] = int(rpc(endpoint, "eth_call", [{"to": cfg["usdc"], "data": data}, block]), 16)
    if env.get("PYTH_API_KEY"):
        report["signedPyth"] = attempt(lambda: verify_pyth(cfg, env, endpoint))
    else:
        report["signedPyth"] = {"error": "PYTH_API_KEY missing"}
    return report


def verify_pyth(cfg, env, endpoint):
    if cfg["hermes"] != "https://pyth.dourolabs.app/hermes":
        raise ProbeError("Unexpected authenticated Hermes destination")
    feed = json.loads((ROOT / "config/monad-mainnet.json").read_text())["controlFeed"]["feedId"]
    query = urllib.parse.urlencode({"ids[]": feed, "encoding": "hex", "parsed": "true"})
    update = request_json(cfg["hermes"] + "/v2/updates/price/latest?" + query,
                          headers={"Authorization": "Bearer " + env["PYTH_API_KEY"]})
    if update.get("binary", {}).get("encoding") != "hex":
        raise ProbeError("Unexpected Hermes encoding")
    payloads = update["binary"]["data"]
    header = rpc(endpoint, "eth_getBlockByNumber", ["latest", False])
    block = header["number"]
    fee = int(rpc(endpoint, "eth_call", [{"to": cfg["pythCore"],
                  "data": calldata("getUpdateFee(bytes[])", payloads)}, block]), 16)
    tx = {"from": SYNTHETIC, "to": cfg["pythCore"], "value": hex(fee),
          "data": calldata("updatePriceFeeds(bytes[])", payloads)}
    rpc(endpoint, "eth_call", [tx, block])
    gas = attempt(lambda: int(rpc(endpoint, "eth_estimateGas", [tx, block]), 16))
    return {"providerAccepted": True, "feedId": feed, "block": int(block, 16), "hash": header["hash"],
            "freshness": freshness(update, datetime.fromtimestamp(int(header["timestamp"], 16), timezone.utc)),
            "providerGasEstimate": gas, "oracleFeeWei": fee, "submittedGasLimit": None,
            "chargedFeeWei": None, "updates": update}


def dry_run(env, endpoint, report):
    cfg = json.loads((ROOT / "config/deploy-testnet.example.json").read_text())
    sender = report["wallet"]["address"] or SYNTHETIC
    for name in ("governor", "guardian", "treasury"):
        cfg[name] = public_address(env.get("TESTNET_" + name.upper()) or sender)
    FOLDER.mkdir(parents=True, exist_ok=True)
    (FOLDER / "testnet-simulation-config.json").write_text(json.dumps(cfg, indent=2) + "\n")
    summary_path = FOLDER / "testnet-simulation.json"
    summary_path.write_text(json.dumps({"status": "incomplete", "broadcast": False}) + "\n")
    env = dict(env, DEPLOYER=sender, DEPLOY_CONFIG="reports/deployment/testnet-simulation-config.json",
               DEPLOY_OUTPUT="reports/deployment/testnet-simulation-manifest.json")
    # This process needs no signing secret. The common deployment script records unsigned calls only.
    env.pop("FUNDED_DEPLOYER_PRIVATE_KEY", None)
    command = ["forge", "script", "script/DeployPripo.s.sol:DeployPripo", "--rpc-url", "monad_testnet",
               "--fork-block-number", str(report["block"]), "--sender", sender, "-vv"]
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = redact_output(result.stdout, load_env())
    (FOLDER / "testnet-simulation.log").write_text(output)
    print(output, end="", flush=True)
    if result.returncode:
        raise ProbeError("Testnet deployment simulation failed; see redacted log")
    manifest = json.loads((FOLDER / "testnet-simulation-manifest.json").read_text())
    plan = json.loads((ROOT / "broadcast/DeployPripo.s.sol/10143/dry-run/run-latest.json").read_text())
    creations = creation_summary(manifest, plan)
    total = sum(item["simulatedGasLimit"] for item in creations)
    result = {"status": "passed", "broadcast": False, "mode": "local-testnet-fork", "chainId": 10143,
              "block": report["block"], "hash": report["hash"], "deployer": sender,
              "syntheticSender": sender == SYNTHETIC, "creations": creations, "totalSimulatedGasLimit": total,
              "gasPriceWei": report["gasPriceWei"], "gasBudgetWeiAtObservedPrice": total * report["gasPriceWei"],
              "submittedGasLimit": None, "chargedFeeWei": None,
              "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "workingTreeDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))}
    summary_path.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Simulated {len(creations)} creations; gas-limit budget {total}. No broadcast.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "dry-run"))
    args = parser.parse_args()
    env, endpoint = testnet_env()
    report = preflight(env, endpoint)
    FOLDER.mkdir(parents=True, exist_ok=True)
    (FOLDER / "testnet-preflight.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Monad testnet 10143: official USDC and Pyth code verified.", flush=True)
    print("Signing key configured:", report["wallet"]["signerConfigured"], flush=True)
    if args.command == "dry-run":
        dry_run(env, endpoint, report)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
