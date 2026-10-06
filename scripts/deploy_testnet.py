#!/usr/bin/env python3
"""Execute explicit Monad-testnet deployment stages and retain receipts. Mainnet is rejected."""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from dry_run_deployment import creation_summary
from monad_preflight import ROOT, ProbeError, rpc
from run_monad_fork import redact_output
from testnet_stage import FOLDER, public_address, testnet_env, wallet


def receipt_cost(tx, receipt):
    if int(receipt["status"], 16) != 1:
        raise ProbeError("Testnet transaction reverted; inspect receipt before continuing")
    return {"hash": receipt["transactionHash"], "block": int(receipt["blockNumber"], 16),
            "gasLimit": int(tx["gas"], 16), "receiptGasUsed": int(receipt["gasUsed"], 16),
            "effectiveGasPriceWei": int(receipt["effectiveGasPrice"], 16),
            "receiptFeeWei": int(receipt["gasUsed"], 16) * int(receipt["effectiveGasPrice"], 16),
            "valueWei": int(tx["value"], 16), "contractAddress": receipt.get("contractAddress")}


def run_forge(command, env, label):
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    output = redact_output(result.stdout, env)
    (FOLDER / f"testnet-{label}.log").write_text(output)
    print(output, end="", flush=True)
    if result.returncode:
        raise ProbeError(f"Testnet {label} failed; inspect the saved redacted log and receipts")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("deploy", "configure", "activate"))
    parser.add_argument("--broadcast", action="store_true", help="Submit the simulated stage on chain 10143")
    args = parser.parse_args()
    env, endpoint = testnet_env()
    signer = wallet(env)
    if not signer["signerConfigured"]:
        raise ProbeError("Configure a funded testnet signing key before executing deployment stages")
    sender = signer["address"]
    env.update(DEPLOYER=sender, DEPLOY_CONFIG="reports/deployment/testnet-config.json",
               DEPLOY_OUTPUT="reports/deployment/testnet-manifest.json")
    FOLDER.mkdir(parents=True, exist_ok=True)
    live_path = FOLDER / f"testnet-{args.stage}-receipts.json"
    if args.stage == "deploy":
        if live_path.exists() or (FOLDER / "testnet-manifest.json").exists():
            raise ProbeError("A deployment record exists; reconcile or resume it instead of creating another set")
        cfg = json.loads((ROOT / "config/deploy-testnet.example.json").read_text())
        for name in ("governor", "guardian", "treasury"):
            cfg[name] = public_address(env.get("TESTNET_" + name.upper()) or sender)
        if env.get("TESTNET_COLLATERAL"):
            cfg["usdc"] = public_address(env["TESTNET_COLLATERAL"])
        (FOLDER / "testnet-config.json").write_text(json.dumps(cfg, indent=2) + "\n")
        env["DEPLOY_OUTPUT"] = "reports/deployment/testnet-plan-manifest.json"
        target, signature = "DeployTestnet", "run()"
    else:
        deployed = json.loads((FOLDER / "testnet-deploy-receipts.json").read_text())
        if deployed.get("status") != "verified" or deployed.get("chainId") != 10143:
            raise ProbeError("Deployment receipts must be verified before governance")
        target, signature = "ConfigureTestnet", args.stage + "()"
    command = ["forge", "script", f"script/DeployTestnet.s.sol:{target}", "--sig", signature,
               "--rpc-url", "monad_testnet", "--sender", sender, "--slow", "-vv"]
    run_forge(command, env, args.stage + "-simulation")
    path = ROOT / f"broadcast/DeployTestnet.s.sol/10143/dry-run/{signature.split('(')[0]}-latest.json"
    # Foundry uses run-latest.json for the default run(), and <function>-latest.json otherwise.
    if not path.exists():
        raise ProbeError("Missing unsigned stage plan")
    plan = json.loads(path.read_text())
    if args.stage == "deploy":
        creation_summary(json.loads((FOLDER / "testnet-plan-manifest.json").read_text()), plan)
    if not args.broadcast:
        print("Simulation only. Nothing submitted.")
        return
    balance_before = int(rpc(endpoint, "eth_getBalance", [sender, "latest"]), 16)
    gas_price = int(rpc(endpoint, "eth_gasPrice", []), 16)
    planned_limit = sum(int(item["transaction"]["gas"], 16) for item in plan["transactions"])
    if balance_before < planned_limit * gas_price * 3:
        raise ProbeError("Testnet MON balance is below the conservative stage gas budget")
    record = {"status": "incomplete", "chainId": 10143, "stage": args.stage, "deployer": sender,
              "startedAt": datetime.now(timezone.utc).isoformat(), "balanceBeforeWei": balance_before,
              "simulatedGasLimit": planned_limit, "observedGasPriceWei": gas_price,
              "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    live_path.write_text(json.dumps(record, indent=2) + "\n")
    if args.stage == "deploy":
        env["DEPLOY_OUTPUT"] = "reports/deployment/testnet-manifest.json"
    run_forge(command + ["--broadcast"], env, args.stage + "-broadcast")
    broadcast_path = ROOT / f"broadcast/DeployTestnet.s.sol/10143/{path.name}"
    broadcast = json.loads(broadcast_path.read_text())
    txs = broadcast.get("transactions", [])
    if not txs:
        raise ProbeError("No submitted transactions recorded")
    costs = []
    for item in txs:
        tx_hash = item.get("hash")
        if not tx_hash:
            raise ProbeError("Missing submitted transaction hash")
        tx = rpc(endpoint, "eth_getTransactionByHash", [tx_hash])
        if tx["from"].lower() != sender.lower():
            raise ProbeError("Unexpected transaction sender")
        costs.append(receipt_cost(tx, rpc(endpoint, "eth_getTransactionReceipt", [tx_hash])))
    if args.stage == "deploy":
        manifest = json.loads((FOLDER / "testnet-manifest.json").read_text())
        created = {item["contractAddress"].lower() for item in costs if item["contractAddress"]}
        if len(costs) != 19 or created != {a.lower() for a in manifest["contracts"]}:
            raise ProbeError("Receipts do not match all 19 deployed contracts")
        for address, expected in zip(manifest["contracts"], manifest["runtimeCodeHashes"]):
            code = rpc(endpoint, "eth_getCode", [address, "latest"])
            actual = subprocess.check_output(["cast", "keccak", code], text=True).strip()
            if actual.lower() != expected.lower():
                raise ProbeError("Deployed runtime hash differs from manifest")
    balance_after = int(rpc(endpoint, "eth_getBalance", [sender, "latest"]), 16)
    record.update(status="verified", transactions=costs, balanceAfterWei=balance_after,
                  balanceDeltaWei=balance_before - balance_after,
                  receiptFeesWei=sum(item["receiptFeeWei"] for item in costs),
                  transferredValueWei=sum(item["valueWei"] for item in costs))
    record["balanceReconciled"] = record["balanceDeltaWei"] == record["receiptFeesWei"] + record["transferredValueWei"]
    live_path.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Verified {len(costs)} testnet transactions. Receipt fees: {record['receiptFeesWei']} wei.")


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
