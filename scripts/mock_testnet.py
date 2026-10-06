#!/usr/bin/env python3
"""Deploy and fund isolated mock-USDC custody on Monad testnet, preserving native-USDC records."""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from deploy_testnet import created_address, keccak, receipt_cost, run_forge
from monad_preflight import ROOT, ProbeError, rpc
from testnet_stage import testnet_env, wallet

FOLDER = ROOT / "reports/deployment/mock-testnet"
MANIFEST = FOLDER / "manifest.json"
SOURCE = ROOT / "reports/deployment/testnet-manifest.json"


def calldata(signature, *args):
    return subprocess.check_output(["cast", "calldata", signature, *map(str, args)], text=True).strip()


def expected_calls(manifest, action):
    vault, factory, token = manifest["vault"], manifest["factory"], manifest["usdc"]
    if action == "activate":
        return [(factory, calldata("activateAdapter(address)", manifest["pythAdapter"]))]
    return [
        (vault, calldata("setBackstopController(address)", manifest["backstop"])),
        (vault, calldata("setRegistrar(address,bool)", factory, "true")),
        (factory, calldata("scheduleAdapter(address)", manifest["pythAdapter"])),
        (token, calldata("approve(address,uint256)", vault, 10_000 * 10**6)),
        (vault, calldata("fundProtocolReserve(uint256)", 10_000 * 10**6)),
    ]


def check_plan(manifest, plan, action):
    if manifest.get("chainId") != 10143 or manifest.get("mockCollateral") is not True:
        raise ProbeError("Expected an explicitly labelled Monad testnet mock manifest")
    txs = plan.get("transactions", [])
    creations = 5 if action == "deploy" else 0
    calls = expected_calls(manifest, action)
    if len(txs) != creations + len(calls):
        raise ProbeError("Unexpected transaction count in mock stage")
    if creations:
        if any(t["transactionType"] != "CREATE" for t in txs[:creations]):
            raise ProbeError("Expected five direct creations with existing libraries reused")
        if [t["contractAddress"].lower() for t in txs[:creations]] != [a.lower() for a in manifest["createdContracts"]]:
            raise ProbeError("Mock creation plan does not match its manifest")
    for item, (target, data) in zip(txs[creations:], calls):
        tx = item["transaction"]
        if item["transactionType"] != "CALL" or tx["to"].lower() != target.lower():
            raise ProbeError("Unexpected mock stage call target")
        if (tx.get("input") or tx.get("data") or "").lower() != data.lower():
            raise ProbeError("Unexpected mock stage calldata or funding amount")
    for item in txs:
        tx = item["transaction"]
        if tx["from"].lower() != manifest["deployer"].lower() or int(tx.get("value", "0x0"), 16) != 0:
            raise ProbeError("Unexpected sender or native-value transfer")


def read_state(endpoint, manifest, block="latest"):
    header = rpc(endpoint, "eth_getBlockByNumber", [block, False])
    block = header["number"]
    def read(target, signature, *args):
        return int(rpc(endpoint, "eth_call", [{"to": target, "data": calldata(signature, *args)}, block]), 16)
    vault, token, factory = manifest["vault"], manifest["usdc"], manifest["factory"]
    for signature, expected in (("token()", token), ("backstopController()", manifest["backstop"]),
                                ("governor()", manifest["governor"]), ("guardian()", manifest["guardian"]),
                                ("treasury()", manifest["treasury"])):
        if read(vault, signature) != int(expected, 16):
            raise ProbeError("Mock vault binding or role mismatch")
    if read(vault, "registrars(address)", factory) != 1 or read(token, "decimals()") != 6:
        raise ProbeError("Mock factory registration or token decimals mismatch")
    ready = read(factory, "adapterReadyAt(address)", manifest["pythAdapter"])
    return {"chainId": 10143, "block": int(block, 16), "hash": header["hash"],
            "timestamp": int(header["timestamp"], 16), "mockCollateral": True,
            "vaultTokenUnits": read(token, "balanceOf(address)", vault),
            "deployerTokenUnits": read(token, "balanceOf(address)", manifest["deployer"]),
            "reserveWad": read(vault, "protocolReserve()"), "adapterReadyAt": ready,
            "adapterAllowed": bool(read(factory, "allowedAdapters(address)", manifest["pythAdapter"])),
            "adapterReadyUtc": datetime.fromtimestamp(ready, timezone.utc).isoformat() if ready else None}


def verify(endpoint, action):
    manifest = json.loads(MANIFEST.read_text())
    journal = FOLDER / f"{action}-receipts.json"
    record = json.loads(journal.read_text())
    plan = json.loads((FOLDER / f"{action}-broadcast.json").read_text())
    check_plan(manifest, plan, action)
    costs = []
    for item in plan["transactions"]:
        tx = rpc(endpoint, "eth_getTransactionByHash", [item["hash"]])
        expected = item["transaction"]
        if tx["from"].lower() != manifest["deployer"].lower() or int(tx["value"], 16) != 0:
            raise ProbeError("Unexpected on-chain mock sender/value")
        if (tx.get("input") or "").lower() != (expected.get("input") or expected.get("data") or "").lower():
            raise ProbeError("On-chain calldata differs from the reviewed plan")
        if (tx.get("to") or "").lower() != (expected.get("to") or "").lower():
            raise ProbeError("On-chain target differs from the reviewed plan")
        receipt = rpc(endpoint, "eth_getTransactionReceipt", [item["hash"]])
        cost = receipt_cost(tx, receipt)
        if item["transactionType"] == "CREATE":
            cost["createdAddress"] = created_address(item, tx, receipt)
        costs.append(cost)
    for address, expected in zip(manifest["contracts"] + [manifest["usdc"]],
                                 manifest["runtimeCodeHashes"] + [manifest["mockTokenCodeHash"]]):
        if keccak(rpc(endpoint, "eth_getCode", [address, "latest"])).lower() != expected.lower():
            raise ProbeError("Mock deployment or reused runtime hash mismatch")
    before = min(t["block"] for t in costs) - 1
    after = max(t["block"] for t in costs)
    sender = manifest["deployer"]
    before_balance = int(rpc(endpoint, "eth_getBalance", [sender, hex(before)]), 16)
    after_balance = int(rpc(endpoint, "eth_getBalance", [sender, hex(after)]), 16)
    state = read_state(endpoint, manifest, hex(after))
    if action == "deploy" and (state["reserveWad"] != 10_000 * 10**18
                               or state["vaultTokenUnits"] != 10_000 * 10**6
                               or state["deployerTokenUnits"] != 90_000 * 10**6):
        raise ProbeError("Initial mock reserve or token balance does not match the funding plan")
    if action == "activate" and not state["adapterAllowed"]:
        raise ProbeError("Pyth adapter is not active after activation")
    fees = sum(t["receiptFeeWei"] for t in costs)
    record.update(status="verified", transactions=costs, state=state, balanceBlockBefore=before,
                  balanceBlockAfter=after, balanceBeforeWei=before_balance, balanceAfterWei=after_balance,
                  receiptFeesWei=fees, balanceDeltaWei=before_balance-after_balance,
                  balanceReconciled=before_balance-after_balance == fees)
    journal.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"status": "verified", "transactions": len(costs), "chargedFeeWei": fees,
                      "balanceReconciled": record["balanceReconciled"], "state": state}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("deploy", "activate", "status"))
    flags = parser.add_mutually_exclusive_group()
    flags.add_argument("--broadcast", action="store_true")
    flags.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    env, endpoint = testnet_env()
    if args.action == "status":
        if args.broadcast or args.verify_only:
            raise ProbeError("Status is read-only")
        print(json.dumps(read_state(endpoint, json.loads(MANIFEST.read_text())), indent=2))
        return
    if args.verify_only:
        verify(endpoint, args.action)
        return
    FOLDER.mkdir(parents=True, exist_ok=True)
    journal = FOLDER / f"{args.action}-receipts.json"
    if journal.exists() or (args.action == "deploy" and MANIFEST.exists()):
        raise ProbeError("Mock stage records exist; verify or reconcile them without redeploying")
    signer = wallet(env)
    if not signer["signerConfigured"]:
        raise ProbeError("Configure a funded testnet signer")
    env.update(DEPLOYER=signer["address"], DEPLOY_OUTPUT=str(SOURCE if args.action == "deploy" else MANIFEST),
               MOCK_DEPLOY_OUTPUT=str(FOLDER / "simulation-manifest.json"))
    script, target, signature = ("DeployMockTestnet.s.sol", "DeployMockTestnet", "run()") if args.action == "deploy" else (
        "DeployTestnet.s.sol", "ConfigureTestnet", "activate()")
    command = ["forge", "script", f"script/{script}:{target}", "--sig", signature,
               "--rpc-url", "monad_testnet", "--sender", signer["address"], "--slow", "-vv"]
    run_forge(command, env, args.action + "-simulation", FOLDER)
    name = signature.split("(")[0] + "-latest.json"
    base = ROOT / "broadcast" / script / "10143"
    plan = json.loads((base / "dry-run" / name).read_text())
    manifest = json.loads((FOLDER / "simulation-manifest.json" if args.action == "deploy" else MANIFEST).read_text())
    check_plan(manifest, plan, args.action)
    if not args.broadcast:
        print("Mock stage simulation passed; no transaction submitted.")
        return
    gas = sum(int(t["transaction"]["gas"], 16) for t in plan["transactions"])
    price = int(rpc(endpoint, "eth_gasPrice", []), 16)
    balance = int(rpc(endpoint, "eth_getBalance", [signer["address"], "latest"]), 16)
    if balance < gas * price * 3:
        raise ProbeError("Insufficient testnet MON for the conservative gas budget")
    record = {"status": "incomplete", "chainId": 10143, "action": args.action, "mockCollateral": True,
              "startedAt": datetime.now(timezone.utc).isoformat(), "simulatedGasLimit": gas,
              "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    journal.write_text(json.dumps(record, indent=2) + "\n")
    env["MOCK_DEPLOY_OUTPUT"] = str(MANIFEST)
    run_forge(command + ["--broadcast"], env, args.action + "-broadcast", FOLDER)
    (FOLDER / f"{args.action}-broadcast.json").write_text((base / name).read_text())
    verify(endpoint, args.action)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
