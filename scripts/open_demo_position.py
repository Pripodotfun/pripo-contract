#!/usr/bin/env python3
"""Open one price-limited PRIPO:DEMO long using 100 mUSDC deposited on Monad testnet."""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from create_demo_market import MARKET
from deploy_testnet import keccak, receipt_cost, run_forge
from mock_testnet import FOLDER, MANIFEST, calldata, read_state
from monad_preflight import ROOT, ProbeError, rpc
from testnet_stage import testnet_env, wallet

DEPOSIT, SIZE, LIMIT = 100 * 10**6, 10**18, 101 * 10**18
JOURNAL = FOLDER / "open-position-receipts.json"
BROADCAST = FOLDER / "open-position-broadcast.json"
OUTPUT = FOLDER / "position.json"
FOUNDRY = ROOT / "broadcast/OpenDemoPosition.s.sol/10143/run-latest.json"


def expected_calls(manifest, market):
    return [(manifest["usdc"], calldata("approve(address,uint256)", manifest["vault"], DEPOSIT)),
            (manifest["vault"], calldata("deposit(uint256)", DEPOSIT)),
            (market["market"], calldata("open(int256,uint256,bytes)", SIZE, LIMIT, "0x"))]


def check_plan(manifest, market, plan):
    if (manifest.get("chainId") != 10143 or manifest.get("mockCollateral") is not True
            or market.get("chainId") != 10143 or market.get("mockCollateral") is not True
            or market.get("symbol") != "PRIPO:DEMO"
            or market["vault"].lower() != manifest["vault"].lower()
            or market["factory"].lower() != manifest["factory"].lower()):
        raise ProbeError("Expected the existing mock Monad testnet demo market")
    txs = plan.get("transactions", [])
    if len(txs) != 3:
        raise ProbeError("Expected exactly approval, deposit and one open")
    for item, (target, data) in zip(txs, expected_calls(manifest, market)):
        tx = item["transaction"]
        if (item["transactionType"] != "CALL" or tx["from"].lower() != manifest["deployer"].lower()
                or tx["to"].lower() != target.lower() or int(tx.get("value", "0x0"), 16) != 0
                or (tx.get("input") or tx.get("data") or "").lower() != data.lower()):
            raise ProbeError("Unexpected position target, amount, limit price, sender or native value")


def verify(endpoint, manifest, market):
    record = json.loads(JOURNAL.read_text())
    if record.get("chainId") != 10143 or record.get("action") != "open-demo-position":
        raise ProbeError("Wrong position journal")
    if not BROADCAST.exists():
        BROADCAST.write_text(FOUNDRY.read_text())
    plan = json.loads(BROADCAST.read_text())
    check_plan(manifest, market, plan)
    costs, receipts = [], []
    for item, (target, data) in zip(plan["transactions"], expected_calls(manifest, market)):
        if not item.get("hash"):
            raise ProbeError("Incomplete broadcast; reconcile existing transactions before retrying")
        tx = rpc(endpoint, "eth_getTransactionByHash", [item["hash"]])
        receipt = rpc(endpoint, "eth_getTransactionReceipt", [item["hash"]])
        if tx is None or receipt is None:
            raise ProbeError("Transaction has not been mined")
        if (tx["from"].lower() != manifest["deployer"].lower() or tx["to"].lower() != target.lower()
                or tx["input"].lower() != data.lower() or int(tx["value"], 16) != 0):
            raise ProbeError("On-chain transaction differs from the reviewed position plan")
        costs.append(receipt_cost(tx, receipt))
        receipts.append(receipt)
    before, after = min(t["block"] for t in costs) - 1, max(t["block"] for t in costs)
    block = hex(after)
    vault, token, sender = (manifest[k] for k in ("vault", "usdc", "deployer"))
    address = market["market"]

    def decode(data):
        return [int(data[i:i+64], 16) for i in range(2, len(data), 64)]

    def words(target, signature, *args, at=block):
        return decode(rpc(endpoint, "eth_call", [{"to": target, "data": calldata(signature, *args)}, at]))

    def expect(target, signature, expected, *args):
        if words(target, signature, *args) != expected:
            raise ProbeError(f"Position verification failed: {signature}")

    if keccak(rpc(endpoint, "eth_getCode", [address, block])).lower() != market["runtimeCodeHash"].lower():
        raise ProbeError("Market runtime differs from verified deployment")
    event = keccak("PositionOpened(address,address,address,int256,uint256,uint256,uint256)")
    logs = [log for log in receipts[-1]["logs"] if log["address"].lower() == address.lower()
            and log["topics"][0].lower() == event.lower()]
    if len(logs) != 1 or [int(t, 16) for t in logs[0]["topics"][1:]] != [int(address, 16), int(sender, 16)]:
        raise ProbeError("Missing or incorrect PositionOpened event")
    operator, size, average, margin, fee = decode(logs[0]["data"])
    if operator != int(sender, 16) or size != SIZE or average > LIMIT or margin + fee > DEPOSIT * 10**12:
        raise ProbeError("Trade exceeded reviewed limits")
    position = words(address, "position(address)", sender)
    if position[:3] != [SIZE, margin, average] or position[5] != 0:
        raise ProbeError("Position size, margin or entry differs from the fill")
    if words(address, "position(address)", sender, at=hex(before))[0] != 0:
        raise ProbeError("Expected a new position, not an increase")
    expect(address, "vault()", [int(vault, 16)])
    expect(vault, "locked(address,address)", [margin], sender, address)
    expect(token, "allowance(address,address)", [0], sender, vault)
    expect(vault, "requireOpenAllowed(address)", [], address)
    free = words(vault, "freeBalance(address)", sender)[0]
    previous_free = words(vault, "freeBalance(address)", sender, at=hex(before))[0]
    if free != previous_free + DEPOSIT * 10**12 - margin - fee:
        raise ProbeError("Free collateral debit does not reconcile")
    ledger = words(vault, "ledger(address)", address)
    old_ledger = words(vault, "ledger(address)", address, at=hex(before))
    if sum(ledger[:3]) - sum(old_ledger[:3]) != fee or ledger[3:] != old_ledger[3:]:
        raise ProbeError("Opening fee ledger does not reconcile")
    state = read_state(endpoint, manifest, block)
    initial = read_state(endpoint, manifest, hex(before))
    if (state["reserveWad"] != initial["reserveWad"]
            or state["vaultTokenUnits"] != initial["vaultTokenUnits"] + DEPOSIT
            or state["deployerTokenUnits"] != initial["deployerTokenUnits"] - DEPOSIT):
        raise ProbeError("Deposit custody or reserve does not reconcile")
    health, liquidatable = words(address, "health(address)", sender)
    if liquidatable:
        raise ProbeError("Opened position is liquidatable")
    state.update(market=address, positionCount=words(address, "positionCount()")[0],
                 insuranceWad=ledger[2], markPriceWad=words(address, "markPrice()")[0],
                 freeBalanceWad=free, lockedWad=margin, healthWad=health, liquidatable=False,
                 longSizeWad=words(address, "longSize()")[0], shortSizeWad=words(address, "shortSize()")[0])
    balance_before = int(rpc(endpoint, "eth_getBalance", [sender, hex(before)]), 16)
    balance_after = int(rpc(endpoint, "eth_getBalance", [sender, block]), 16)
    fees = sum(t["receiptFeeWei"] for t in costs)
    record.update(status="verified", transactions=costs, state=state,
                  position={"market": address, "trader": sender, "sizeWad": SIZE, "side": "long",
                            "entryCostWad": position[2], "averagePriceWad": average, "marginWad": margin,
                            "feeWad": fee, "limitPriceWad": LIMIT, "depositUnits": DEPOSIT},
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
    manifest, market = json.loads(MANIFEST.read_text()), json.loads(MARKET.read_text())
    if args.verify_only:
        verify(endpoint, manifest, market)
        return
    if JOURNAL.exists() or OUTPUT.exists():
        raise ProbeError("Position records exist; use --verify-only or reconcile before retrying")
    signer = wallet(env)
    if not signer["signerConfigured"] or signer["address"].lower() != manifest["deployer"].lower():
        raise ProbeError("Configure the mock deployment's funded signer")
    simulation = FOLDER / "position-simulation.json"
    env.update(DEPLOYER=signer["address"], DEPLOY_OUTPUT=str(MANIFEST), DEMO_MARKET_INPUT=str(MARKET),
               DEMO_POSITION_OUTPUT=str(simulation))
    command = ["forge", "script", "script/OpenDemoPosition.s.sol:OpenDemoPosition", "--sig", "run()",
               "--rpc-url", "monad_testnet", "--sender", signer["address"], "--slow", "-vv"]
    run_forge(command, env, "position-simulation", FOLDER)
    plan = json.loads((FOUNDRY.parent / "dry-run/run-latest.json").read_text())
    check_plan(manifest, market, plan)
    print(simulation.read_text())
    if not args.broadcast:
        print("Position simulation passed; no transaction submitted.")
        return
    gas = sum(int(t["transaction"]["gas"], 16) for t in plan["transactions"])
    price = int(rpc(endpoint, "eth_gasPrice", []), 16)
    balance = int(rpc(endpoint, "eth_getBalance", [signer["address"], "latest"]), 16)
    if balance < gas * price * 3:
        raise ProbeError("Insufficient testnet MON for the conservative gas budget")
    record = {"status": "incomplete", "chainId": 10143, "action": "open-demo-position",
              "startedAt": datetime.now(timezone.utc).isoformat(), "simulatedGasLimit": gas,
              "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
    OUTPUT.write_text(simulation.read_text())
    env["DEMO_POSITION_OUTPUT"] = str(OUTPUT)
    run_forge(command + ["--broadcast"], env, "position-broadcast", FOLDER)
    BROADCAST.write_text(FOUNDRY.read_text())
    verify(endpoint, manifest, market)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
