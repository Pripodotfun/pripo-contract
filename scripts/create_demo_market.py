#!/usr/bin/env python3
"""Simulate, create and verify PRIPO:DEMO on the existing mock Monad testnet deployment."""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from deploy_testnet import keccak, receipt_cost, run_forge
from mock_testnet import FOLDER, MANIFEST, calldata, read_state
from monad_preflight import ROOT, ProbeError, rpc
from testnet_stage import testnet_env, wallet

SYMBOL = "PRIPO:DEMO"
PRICE, DEPTH, SEED = 100 * 10**18, 200_000 * 10**18, 2_000 * 10**6
JOURNAL = FOLDER / "market-receipts.json"
BROADCAST = FOLDER / "market-broadcast.json"
MARKET = FOLDER / "market.json"
FOUNDRY = ROOT / "broadcast/CreateDemoMarket.s.sol/10143/run-latest.json"


def expected_calls(manifest):
    params = f"({SYMBOL},{manifest['nullAdapter']},0x{'00' * 32},{PRICE},{DEPTH},{SEED})"
    return [(manifest["usdc"], calldata("approve(address,uint256)", manifest["factory"], SEED)),
            (manifest["factory"], calldata("createMarket((string,address,bytes32,uint256,uint256,uint256))", params))]


def check_plan(manifest, plan):
    if manifest.get("chainId") != 10143 or manifest.get("mockCollateral") is not True:
        raise ProbeError("Expected the mock Monad testnet deployment")
    txs = plan.get("transactions", [])
    if len(txs) != 2:
        raise ProbeError("Expected exactly approval and market creation")
    for item, (target, data) in zip(txs, expected_calls(manifest)):
        tx = item["transaction"]
        if (item["transactionType"] != "CALL" or tx["from"].lower() != manifest["deployer"].lower()
                or tx["to"].lower() != target.lower() or int(tx.get("value", "0x0"), 16) != 0
                or (tx.get("input") or tx.get("data") or "").lower() != data.lower()):
            raise ProbeError("Unexpected demo market target, calldata, sender or native value")


def verify(endpoint, manifest):
    record = json.loads(JOURNAL.read_text())
    if record.get("chainId") != 10143 or record.get("action") != "create-demo-market":
        raise ProbeError("Wrong market journal")
    # Recover receipts after an interrupted broadcast without signing or resubmitting.
    if not BROADCAST.exists():
        BROADCAST.write_text(FOUNDRY.read_text())
    plan = json.loads(BROADCAST.read_text())
    check_plan(manifest, plan)
    costs, receipts = [], []
    for item, (target, data) in zip(plan["transactions"], expected_calls(manifest)):
        if not item.get("hash"):
            raise ProbeError("Incomplete broadcast; reconcile existing transactions before retrying")
        tx = rpc(endpoint, "eth_getTransactionByHash", [item["hash"]])
        receipt = rpc(endpoint, "eth_getTransactionReceipt", [item["hash"]])
        if tx is None or receipt is None:
            raise ProbeError("Transaction has not been mined")
        if (tx["from"].lower() != manifest["deployer"].lower() or tx["to"].lower() != target.lower()
                or tx["input"].lower() != data.lower() or int(tx["value"], 16) != 0):
            raise ProbeError("On-chain transaction differs from the reviewed creation plan")
        costs.append(receipt_cost(tx, receipt))
        receipts.append(receipt)
    before, after = min(t["block"] for t in costs) - 1, max(t["block"] for t in costs)
    block = hex(after)

    def words(target, signature, *args):
        result = rpc(endpoint, "eth_call", [{"to": target, "data": calldata(signature, *args)}, block])[2:]
        return [int(result[i:i+64], 16) for i in range(0, len(result), 64)]

    def expect(target, signature, expected, *args):
        if words(target, signature, *args) != expected:
            raise ProbeError(f"Market verification failed: {signature}")

    factory, vault, token, sender = (manifest[k] for k in ("factory", "vault", "usdc", "deployer"))
    address = "0x" + format(words(factory, "marketForSymbol(bytes32)", keccak(SYMBOL))[0], "040x")
    expect(factory, "predictAddress(string)", [int(address, 16)], SYMBOL)
    expect(factory, "isMarket(address)", [1], address)
    code = rpc(endpoint, "eth_getCode", [address, block])
    clone = "0x363d3d373d3d3d363d73" + manifest["marketImplementation"][2:] + "5af43d82803e903d91602b57fd5bf3"
    if code.lower() != clone.lower():
        raise ProbeError("Wrong clone implementation")
    market = json.loads(MARKET.read_text())
    if address != market["market"].lower() or keccak(code).lower() != market["runtimeCodeHash"].lower():
        raise ProbeError("Created market differs from simulation")
    event = keccak("MarketCreated(address,address,string,bool,uint256,uint256)")
    logs = [log for log in receipts[-1]["logs"] if log["address"].lower() == factory.lower()
            and log["topics"][0].lower() == event.lower()]
    # A dynamic string gives the same encoding as the arguments after a dummy selector.
    event_data = "0x" + calldata("eventData(string,bool,uint256,uint256)", SYMBOL, "false", DEPTH, SEED)[10:]
    if (len(logs) != 1 or [int(t, 16) for t in logs[0]["topics"][1:]] != [int(address, 16), int(sender, 16)]
            or logs[0]["data"].lower() != event_data.lower()):
        raise ProbeError("Missing or incorrect MarketCreated event")
    expect(address, "vault()", [int(vault, 16)])
    expect(address, "externalIndex()", [0])
    expect(address, "feedId()", [0])
    expect(address, "markPrice()", [PRICE])
    expect(address, "openInterest()", [0, 0, 20_000 * 10**18])
    expect(address, "positionCount()", [0])
    base = DEPTH * 10**18 // PRICE
    expect(address, "ammState()", [base, DEPTH, base * DEPTH, base, DEPTH, 0])
    config = words(factory, "launchConfig(address,address)", sender, manifest["nullAdapter"])
    config[19] = costs[-1]["block"]  # statusSince is initialized in the creation block.
    expect(address, "config()", config)
    expect(vault, "registrarOf(address)", [int(factory, 16)], address)
    expect(vault, "creatorOf(address)", [int(sender, 16)], address)
    expect(vault, "ledger(address)", [0, 0, SEED * 10**12, 0, 0, 0], address)
    expect(vault, "requireOpenAllowed(address)", [], address)
    expect(token, "allowance(address,address)", [0], sender, factory)
    state = read_state(endpoint, manifest, block)
    initial = read_state(endpoint, manifest, hex(before))
    if (state["reserveWad"] != initial["reserveWad"] or state["reserveWad"] < 10_000 * 10**18
            or state["vaultTokenUnits"] != initial["vaultTokenUnits"] + SEED
            or state["deployerTokenUnits"] != initial["deployerTokenUnits"] - SEED):
        raise ProbeError("Seed funding or reserve balance mismatch")
    balance_before = int(rpc(endpoint, "eth_getBalance", [sender, hex(before)]), 16)
    balance_after = int(rpc(endpoint, "eth_getBalance", [sender, block]), 16)
    fees = sum(t["receiptFeeWei"] for t in costs)
    state.update(marketCount=words(factory, "marketCount()")[0], status="Active", opensAllowed=True,
                 insuranceWad=SEED * 10**12, maxLeverageX=config[7], oiCapWad=20_000 * 10**18)
    record.update(status="verified", market=market, transactions=costs, state=state,
                  balanceBlockBefore=before, balanceBlockAfter=after, balanceBeforeWei=balance_before,
                  balanceAfterWei=balance_after, balanceDeltaWei=balance_before-balance_after,
                  receiptFeesWei=fees, balanceReconciled=balance_before-balance_after == fees,
                  submittedGasLimit=sum(t["gasLimit"] for t in costs),
                  receiptGasUsed=sum(t["receiptGasUsed"] for t in costs))
    JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    flags = parser.add_mutually_exclusive_group()
    flags.add_argument("--broadcast", action="store_true")
    flags.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    env, endpoint = testnet_env()
    manifest = json.loads(MANIFEST.read_text())
    if args.verify_only:
        verify(endpoint, manifest)
        return
    if JOURNAL.exists() or MARKET.exists():
        raise ProbeError("Market records exist; use --verify-only or reconcile before retrying")
    signer = wallet(env)
    if not signer["signerConfigured"] or signer["address"].lower() != manifest["deployer"].lower():
        raise ProbeError("Configure the mock deployment's funded signer")
    env.update(DEPLOYER=signer["address"], DEPLOY_OUTPUT=str(MANIFEST),
               DEMO_MARKET_OUTPUT=str(FOLDER / "market-simulation.json"))
    command = ["forge", "script", "script/CreateDemoMarket.s.sol:CreateDemoMarket", "--sig", "run()",
               "--rpc-url", "monad_testnet", "--sender", signer["address"], "--slow", "-vv"]
    run_forge(command, env, "market-simulation", FOLDER)
    plan = json.loads((FOUNDRY.parent / "dry-run/run-latest.json").read_text())
    check_plan(manifest, plan)
    if not args.broadcast:
        print("Demo market simulation passed; no transaction submitted.")
        return
    gas = sum(int(t["transaction"]["gas"], 16) for t in plan["transactions"])
    price = int(rpc(endpoint, "eth_gasPrice", []), 16)
    balance = int(rpc(endpoint, "eth_getBalance", [signer["address"], "latest"]), 16)
    if balance < gas * price * 3:
        raise ProbeError("Insufficient testnet MON for the conservative gas budget")
    record = {"status": "incomplete", "chainId": 10143, "action": "create-demo-market",
              "startedAt": datetime.now(timezone.utc).isoformat(), "simulatedGasLimit": gas,
              "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
    MARKET.write_text((FOLDER / "market-simulation.json").read_text())
    env["DEMO_MARKET_OUTPUT"] = str(MARKET)
    run_forge(command + ["--broadcast"], env, "market-broadcast", FOLDER)
    BROADCAST.write_text(FOUNDRY.read_text())
    verify(endpoint, manifest)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
