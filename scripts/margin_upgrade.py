#!/usr/bin/env python3
"""Journaled margin-entry implementation upgrade for the existing mock Monad testnet factory."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import subprocess

from deploy_testnet import created_address, keccak, receipt_cost, run_forge
from mock_testnet import MANIFEST, calldata
from monad_preflight import ROOT, ProbeError, rpc
from testnet_stage import testnet_env, wallet

FOLDER = ROOT / "reports/deployment/margin-upgrade"
UPGRADE = FOLDER / "implementation.json"
SCRIPT = "UpgradeMarginTestnet.s.sol"
SYMBOL = "PRIPO:DEMO-V2"
FACTORY = "0x133a614cbe2cba1789e67e0898c0f5c56eb7bbf0"
VAULT = "0x1980b3a41393f610a8be552c71bae3f42aab6735"
TOKEN = "0xd0f68cf8fe7725a34ee8312515fc27ad955d8fbf"


def source_digest():
    paths = sorted((ROOT / "src").rglob("*.sol")) + [ROOT / "script" / SCRIPT,
        ROOT / "test/fork/MonadMarginUpgrade.t.sol", ROOT / "scripts/margin_upgrade.py", ROOT / "foundry.toml"]
    digest = hashlib.sha256()
    for path in paths:
        digest.update(str(path.relative_to(ROOT)).encode()); digest.update(path.read_bytes())
    return digest.hexdigest()


def write(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def read(endpoint, target, signature, *args, block="latest"):
    return int(rpc(endpoint, "eth_call", [{"to": target, "data": calldata(signature, *args)}, block]), 16)


def base_manifest():
    m = json.loads(MANIFEST.read_text())
    if (m.get("chainId") != 10143 or m.get("mockCollateral") is not True
            or m["factory"].lower() != FACTORY or m["vault"].lower() != VAULT or m["usdc"].lower() != TOKEN):
        raise ProbeError("Only the existing mock testnet deployment is supported")
    return m


def check_upgrade(m, u):
    if (u.get("chainId") != 10143 or u.get("mockCollateral") is not True
            or any(u.get(k, "").lower() != m[k].lower() for k in ("factory", "vault", "deployer"))
            or u.get("previousImplementation", "").lower() != m["marketImplementation"].lower()
            or len(u.get("contracts", [])) != 12 or len(u.get("runtimeCodeHashes", [])) != 12
            or u["contracts"][0].lower() != u.get("implementation", "").lower()
            or len(set(a.lower() for a in u["contracts"])) != 12):
        raise ProbeError("Upgrade manifest does not match the existing deployment")


def expected_calls(m, u, stage):
    if stage == "deploy": return []
    if stage == "schedule": return [(m["factory"], calldata("scheduleImplementation(address)", u["implementation"]))]
    if stage == "activate": return [(m["factory"], calldata("activateImplementation()"))]
    params = f"({SYMBOL},{m['nullAdapter']},0x{'00' * 32},{100 * 10**18},{200_000 * 10**18},{2_000 * 10**6})"
    return [(m["usdc"], calldata("approve(address,uint256)", m["factory"], 2_000 * 10**6)),
            (m["factory"], calldata("createMarket((string,address,bytes32,uint256,uint256,uint256))", params))]


def check_plan(m, u, stage, plan):
    check_upgrade(m, u)
    txs = plan.get("transactions", [])
    calls = expected_calls(m, u, stage)
    if stage == "deploy":
        if not txs or len(txs) > 12: raise ProbeError("Unexpected implementation deployment count")
        addresses = [t.get("contractAddress", "").lower() for t in txs]
        if (len(set(addresses)) != len(addresses) or not set(addresses) <= set(a.lower() for a in u["contracts"])
                or addresses.count(u["implementation"].lower()) != 1):
            raise ProbeError("Unexpected implementation deployment addresses")
        for item in txs:
            if item["transactionType"] not in ("CREATE", "CREATE2"):
                raise ProbeError("Implementation deployment must not include calls")
            if item["contractAddress"].lower() == u["implementation"].lower() and item["transactionType"] != "CREATE":
                raise ProbeError("Expected a direct Market creation")
    elif len(txs) != len(calls):
        raise ProbeError("Unexpected governance/creation transaction count")
    for item in txs:
        tx = item["transaction"]
        if tx.get("from", "").lower() != m["deployer"].lower() or int(tx.get("value", "0x0"), 16) != 0:
            raise ProbeError("Unexpected transaction sender or native value")
    for item, (target, data) in zip(txs, calls):
        tx = item["transaction"]
        if (item["transactionType"] != "CALL" or tx.get("to", "").lower() != target.lower()
                or (tx.get("input") or tx.get("data") or "").lower() != data.lower()):
            raise ProbeError("Unexpected governance/creation target or calldata")


def status(endpoint, m):
    h = rpc(endpoint, "eth_getBlockByNumber", ["latest", False]); block = h["number"]
    ready = read(endpoint, m["factory"], "implementationReadyAt()", block=block)
    result = {"chainId": 10143, "block": int(block, 16), "blockHash": h["hash"], "timestamp": int(h["timestamp"], 16),
              "factory": m["factory"], "implementation": "0x" + format(read(endpoint, m["factory"], "marketImplementation()", block=block), "040x"),
              "pendingImplementation": "0x" + format(read(endpoint, m["factory"], "pendingImplementation()", block=block), "040x"),
              "readyAt": ready, "readyUtc": datetime.fromtimestamp(ready, timezone.utc).isoformat() if ready else None,
              "activationReady": bool(ready and int(h["timestamp"], 16) >= ready),
              "market": "0x" + format(read(endpoint, m["factory"], "marketForSymbol(bytes32)", keccak(SYMBOL), block=block), "040x")}
    write(FOLDER / "status.json", result)
    return result


def verify(endpoint, m, stage):
    u = json.loads(UPGRADE.read_text()); check_upgrade(m, u)
    journal = FOLDER / f"{stage}-receipts.json"; record = json.loads(journal.read_text())
    if record.get("chainId") != 10143 or record.get("stage") != stage:
        raise ProbeError("Wrong stage journal")
    signature = "run" if stage == "deploy" else stage
    saved = FOLDER / f"{stage}-broadcast.json"
    if not saved.exists():
        saved.write_text((ROOT / f"broadcast/{SCRIPT}/10143/{signature}-latest.json").read_text())
    plan = json.loads(saved.read_text()); check_plan(m, u, stage, plan)
    costs, receipts = [], []
    for item in plan["transactions"]:
        if not item.get("hash"): raise ProbeError("Incomplete broadcast: reconcile saved transactions before retrying")
        tx = rpc(endpoint, "eth_getTransactionByHash", [item["hash"]])
        receipt = rpc(endpoint, "eth_getTransactionReceipt", [item["hash"]])
        expected = item["transaction"]
        if (tx["from"].lower() != m["deployer"].lower() or int(tx["value"], 16) != 0
                or (tx.get("to") or "").lower() != (expected.get("to") or "").lower()
                or tx["input"].lower() != (expected.get("input") or expected.get("data") or "").lower()):
            raise ProbeError("Mined transaction differs from reviewed plan")
        cost = receipt_cost(tx, receipt)
        if stage == "deploy": cost["createdAddress"] = created_address(item, tx, receipt)
        costs.append(cost); receipts.append(receipt)
    after = max(t["block"] for t in costs); before = min(t["block"] for t in costs) - 1; block = hex(after)
    for address, expected in zip(u["contracts"], u["runtimeCodeHashes"]):
        if keccak(rpc(endpoint, "eth_getCode", [address, block])).lower() != expected.lower():
            raise ProbeError("Implementation/module runtime hash mismatch")
    if read(endpoint, u["implementation"], "marginEntryVersion()", block=block) != 1:
        raise ProbeError("Missing margin entry capability")
    current = read(endpoint, m["factory"], "marketImplementation()", block=block)
    pending = read(endpoint, m["factory"], "pendingImplementation()", block=block)
    ready = read(endpoint, m["factory"], "implementationReadyAt()", block=block)
    if stage in ("deploy", "schedule") and current != int(u["previousImplementation"], 16):
        raise ProbeError("Existing implementation changed before activation")
    if stage == "schedule":
        header = rpc(endpoint, "eth_getBlockByNumber", [block, False])
        delay = read(endpoint, m["factory"], "GOVERNANCE_DELAY()", block=block)
        if pending != int(u["implementation"], 16) or ready != int(header["timestamp"], 16) + delay:
            raise ProbeError("Implementation schedule mismatch")
        record.update(readyAt=ready, readyUtc=datetime.fromtimestamp(ready, timezone.utc).isoformat())
        signature = keccak("ImplementationScheduled(address,uint256)")
        topics = [signature, "0x" + u["implementation"][2:].lower().rjust(64, "0")]
        data = "0x" + calldata("eventData(uint256)", ready)[10:]
        if not any(log["address"].lower() == m["factory"].lower() and log["topics"] == topics
                   and log["data"].lower() == data.lower() for log in receipts[-1]["logs"]):
            raise ProbeError("Missing implementation schedule event")
    if stage in ("activate", "create") and (current != int(u["implementation"], 16) or pending != 0 or ready != 0):
        raise ProbeError("Activation mismatch")
    if stage == "create":
        created = json.loads((FOLDER / "market.json").read_text()); address = created["market"]
        if read(endpoint, m["factory"], "marketForSymbol(bytes32)", keccak(SYMBOL), block=block) != int(address, 16):
            raise ProbeError("Market registry mismatch")
        clone = "0x363d3d373d3d3d363d73" + u["implementation"][2:] + "5af43d82803e903d91602b57fd5bf3"
        if rpc(endpoint, "eth_getCode", [address, block]).lower() != clone.lower(): raise ProbeError("Wrong clone")
        if read(endpoint, address, "marginEntryVersion()", block=block) != 1: raise ProbeError("Wrong market capability")
        if read(endpoint, address, "markPrice()", block=block) != 100 * 10**18: raise ProbeError("Wrong initial price")
        if read(endpoint, address, "positionCount()", block=block) != 0: raise ProbeError("Unexpected initial position")
        if read(endpoint, address, "vault()", block=block) != int(m["vault"], 16): raise ProbeError("Wrong market vault")
        for signature, delta, args in (("balanceOf(address)", 2_000 * 10**6, [m["vault"]]),
                                       ("balanceOf(address)", -2_000 * 10**6, [m["deployer"]])):
            if read(endpoint, m["usdc"], signature, *args, block=block) - read(endpoint, m["usdc"], signature, *args, block=hex(before)) != delta:
                raise ProbeError("Seed token custody mismatch")
        if read(endpoint, m["vault"], "protocolReserve()", block=block) != read(endpoint, m["vault"], "protocolReserve()", block=hex(before)):
            raise ProbeError("Reserve changed during market creation")
        ledger = rpc(endpoint, "eth_call", [{"to": m["vault"], "data": calldata("ledger(address)", address)}, block])[2:]
        if [int(ledger[i:i+64], 16) for i in range(0, len(ledger), 64)] != [0, 0, 2_000 * 10**18, 0, 0, 0]:
            raise ProbeError("Wrong initial market ledger")
        if read(endpoint, m["usdc"], "allowance(address,address)", m["deployer"], m["factory"], block=block) != 0:
            raise ProbeError("Unused token approval")
        record["market"] = created
    before_balance = int(rpc(endpoint, "eth_getBalance", [m["deployer"], hex(before)]), 16)
    after_balance = int(rpc(endpoint, "eth_getBalance", [m["deployer"], block]), 16)
    fees = sum(t["receiptFeeWei"] for t in costs)
    record.update(transactions=costs, balanceBlockBefore=before, balanceBlockAfter=after,
                  balanceBeforeWei=before_balance, balanceAfterWei=after_balance, receiptFeesWei=fees,
                  balanceReconciled=before_balance - after_balance == fees)
    if not record["balanceReconciled"]:
        write(journal, record); raise ProbeError("Receipt fees do not match historical balance change")
    record["status"] = "verified"; write(journal, record)
    print(json.dumps({"stage": stage, "status": "verified", "transactions": len(costs), "receiptFeesWei": fees,
                      "implementation": u["implementation"], "readyUtc": record.get("readyUtc")}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("status", "rehearse", "deploy", "schedule", "activate", "create"))
    flags = parser.add_mutually_exclusive_group(); flags.add_argument("--broadcast", action="store_true"); flags.add_argument("--verify-only", action="store_true")
    args = parser.parse_args(); env, endpoint = testnet_env(); m = base_manifest(); FOLDER.mkdir(parents=True, exist_ok=True)
    if args.stage in ("status", "rehearse"):
        if args.broadcast or args.verify_only: raise ProbeError("Read-only stages cannot broadcast")
        state = status(endpoint, m)
        if args.stage == "status": print(json.dumps(state, indent=2)); return
        env.pop("FUNDED_DEPLOYER_PRIVATE_KEY", None)
        env.update(MARGIN_UPGRADE_FORK="true", MARGIN_UPGRADE_BLOCK=str(state["block"]))
        run_forge(["forge", "test", "--match-path", "test/fork/MonadMarginUpgrade.t.sol", "-vv"], env, "rehearsal", FOLDER)
        write(FOLDER / "rehearsal.json", {"status": "passed", "block": state["block"], "blockHash": state["blockHash"],
                                        "sourceDigest": source_digest(), "broadcast": False})
        return
    if args.verify_only: verify(endpoint, m, args.stage); return
    journal = FOLDER / f"{args.stage}-receipts.json"
    if journal.exists(): raise ProbeError("Stage journal exists; verify/reconcile it before any retry")
    signer = wallet(env)
    if not signer["signerConfigured"] or signer["address"].lower() != m["deployer"].lower():
        raise ProbeError("Configure the existing deployment's funded signer")
    if args.stage == "deploy":
        if UPGRADE.exists(): raise ProbeError("Implementation manifest already exists; reconcile before retrying")
        rehearsal = json.loads((FOLDER / "rehearsal.json").read_text())
        if rehearsal.get("status") != "passed" or rehearsal.get("sourceDigest") != source_digest():
            raise ProbeError("Run rehearsal for the current sources first")
        target, signature = "DeployMarginImplementation", "run"
    else:
        prior = {"schedule": "deploy", "activate": "schedule", "create": "activate"}[args.stage]
        if json.loads((FOLDER / f"{prior}-receipts.json").read_text()).get("status") != "verified":
            raise ProbeError("Previous stage must be verified")
        target, signature = "ConfigureMarginImplementation", args.stage
    env.update(DEPLOYER=signer["address"], DEPLOY_OUTPUT=str(MANIFEST),
               MARGIN_OUTPUT=str(FOLDER / "implementation-plan.json" if args.stage == "deploy" else UPGRADE),
               MARGIN_MARKET_OUTPUT=str(FOLDER / "market-plan.json"))
    command = ["forge", "script", f"script/{SCRIPT}:{target}", "--sig", signature + "()", "--rpc-url", "monad_testnet",
               "--sender", signer["address"], "--slow", "-vv"]
    run_forge(command, env, args.stage + "-simulation", FOLDER)
    u = json.loads((FOLDER / "implementation-plan.json" if args.stage == "deploy" else UPGRADE).read_text())
    plan = json.loads((ROOT / f"broadcast/{SCRIPT}/10143/dry-run/{signature}-latest.json").read_text())
    check_plan(m, u, args.stage, plan)
    gas = sum(int(t["transaction"]["gas"], 16) for t in plan["transactions"])
    if not args.broadcast: print(f"Verified simulation: {len(plan['transactions'])} transactions, {gas} gas. Nothing submitted."); return
    checked = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", "src", "script/UpgradeMarginTestnet.s.sol",
                              "scripts/margin_upgrade.py", "test/fork/MonadMarginUpgrade.t.sol", "foundry.toml"], cwd=ROOT)
    if checked.returncode: raise ProbeError("Commit deployment source changes before broadcasting")
    for path in ("script/UpgradeMarginTestnet.s.sol", "scripts/margin_upgrade.py", "test/fork/MonadMarginUpgrade.t.sol"):
        if not subprocess.check_output(["git", "ls-files", "--", path], cwd=ROOT).strip():
            raise ProbeError("Commit the deployment runner before broadcasting")
    price = int(rpc(endpoint, "eth_gasPrice", []), 16)
    if int(rpc(endpoint, "eth_getBalance", [signer["address"], "latest"]), 16) < gas * price * 3:
        raise ProbeError("Insufficient testnet MON for conservative gas budget")
    record = {"status": "incomplete", "chainId": 10143, "stage": args.stage, "startedAt": datetime.now(timezone.utc).isoformat(),
              "simulatedGasLimit": gas, "sourceDigest": source_digest(),
              "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    write(journal, record)
    if args.stage == "deploy": write(UPGRADE, u)
    if args.stage == "create": (FOLDER / "market.json").write_text((FOLDER / "market-plan.json").read_text())
    env.update(MARGIN_OUTPUT=str(UPGRADE), MARGIN_MARKET_OUTPUT=str(FOLDER / "market.json"))
    run_forge(command + ["--broadcast"], env, args.stage + "-broadcast", FOLDER)
    verify(endpoint, m, args.stage)


if __name__ == "__main__":
    try: main()
    except ProbeError as exc: raise SystemExit(str(exc)) from None
