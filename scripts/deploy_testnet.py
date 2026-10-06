#!/usr/bin/env python3
"""Execute explicit Monad-testnet deployment stages and retain receipts. Mainnet is rejected."""
import argparse
from concurrent.futures import ThreadPoolExecutor
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


def keccak(data):
    return subprocess.check_output(["cast", "keccak", data], text=True).strip()


def create2_address(factory, salt, initcode):
    return "0x" + keccak("0xff" + factory[2:] + salt + keccak("0x" + initcode)[2:])[-40:]


def created_address(item, tx, receipt):
    if item["transactionType"] == "CREATE":
        if tx.get("to") or not receipt.get("contractAddress"):
            raise ProbeError("Expected a direct creation receipt")
        actual = receipt["contractAddress"]
    elif item["transactionType"] == "CREATE2":
        factory = "0x4e59b44847b379578588920ca78fbf26c0b4956c"
        data = tx.get("input", "").removeprefix("0x")
        if (tx.get("to") or "").lower() != factory or len(data) <= 64:
            raise ProbeError("Unexpected deterministic deployment transaction")
        # The canonical deterministic deployment proxy consumes salt || initcode.
        actual = create2_address(factory, data[:64], data[64:])
    else:
        raise ProbeError("Unexpected transaction in deployment receipts")
    if actual.lower() != item["contractAddress"].lower():
        raise ProbeError("On-chain creation address differs from the recorded plan")
    return actual


def verify_stage(endpoint, stage, live_path):
    record = json.loads(live_path.read_text())
    if record.get("chainId") != 10143 or record.get("stage") != stage:
        raise ProbeError("Receipt journal does not match this stage")
    sender = record["deployer"]
    saved = FOLDER / f"testnet-{stage}-broadcast.json"
    if not saved.exists():
        name = "run" if stage == "deploy" else stage
        source = ROOT / f"broadcast/DeployTestnet.s.sol/10143/{name}-latest.json"
        saved.write_text(source.read_text())
    broadcast = json.loads(saved.read_text())
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
        receipt = rpc(endpoint, "eth_getTransactionReceipt", [tx_hash])
        cost = receipt_cost(tx, receipt)
        if stage == "deploy":
            cost["createdAddress"] = created_address(item, tx, receipt)
        costs.append(cost)
    record["transactions"] = costs
    live_path.write_text(json.dumps(record, indent=2) + "\n")
    if stage == "deploy":
        manifest = json.loads((FOLDER / "testnet-manifest.json").read_text())
        created = {item["createdAddress"].lower() for item in costs}
        if len(costs) != 19 or created != {a.lower() for a in manifest["contracts"]}:
            raise ProbeError("Receipts do not match all 19 deployed contracts")
        for address, expected in zip(manifest["contracts"], manifest["runtimeCodeHashes"]):
            code = rpc(endpoint, "eth_getCode", [address, "latest"])
            if keccak(code).lower() != expected.lower():
                raise ProbeError("Deployed runtime hash differs from manifest")
    before_block = min(item["block"] for item in costs) - 1
    after_block = max(item["block"] for item in costs)
    # Historical boundaries keep a later verification independent of subsequent wallet activity.
    balance_before = int(rpc(endpoint, "eth_getBalance", [sender, hex(before_block)]), 16)
    balance_after = int(rpc(endpoint, "eth_getBalance", [sender, hex(after_block)]), 16)
    record.update(status="verified", balanceBeforeWei=balance_before, balanceAfterWei=balance_after,
                  balanceBlockBefore=before_block, balanceBlockAfter=after_block,
                  balanceDeltaWei=balance_before - balance_after,
                  receiptFeesWei=sum(item["receiptFeeWei"] for item in costs),
                  transferredValueWei=sum(item["valueWei"] for item in costs))
    record["balanceReconciled"] = record["balanceDeltaWei"] == record["receiptFeesWei"] + record["transferredValueWei"]
    live_path.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Verified {len(costs)} testnet transactions. Receipt fees: {record['receiptFeesWei']} wei.")


def run_forge(command, env, label, folder=FOLDER):
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    output = redact_output(result.stdout, env)
    (folder / f"testnet-{label}.log").write_text(output)
    print(output, end="", flush=True)
    if result.returncode:
        raise ProbeError(f"Testnet {label} failed; inspect the saved redacted log and receipts")


def status(endpoint):
    manifest = json.loads((FOLDER / "testnet-manifest.json").read_text())
    if manifest.get("chainId") != 10143:
        raise ProbeError("Expected the testnet manifest")
    header = rpc(endpoint, "eth_getBlockByNumber", ["latest", False])
    block = header["number"]
    vault, factory = manifest["vault"], manifest["factory"]
    calls = [
        ("governor", vault, "governor()", []), ("guardian", vault, "guardian()", []),
        ("treasury", vault, "treasury()", []), ("token", vault, "token()", []),
        ("backstop", vault, "backstopController()", []),
        ("factoryRegistered", vault, "registrars(address)", [factory]),
        ("reserveWad", vault, "protocolReserve()", []),
        ("adapterAllowed", factory, "allowedAdapters(address)", [manifest["pythAdapter"]]),
        ("adapterReadyAt", factory, "adapterReadyAt(address)", [manifest["pythAdapter"]]),
        ("deployerUsdcUnits", manifest["usdc"], "balanceOf(address)", [manifest["deployer"]]),
    ]
    def read(call):
        name, target, signature, args = call
        data = subprocess.check_output(["cast", "calldata", signature, *args], text=True).strip()
        return name, int(rpc(endpoint, "eth_call", [{"to": target, "data": data}, block]), 16)
    with ThreadPoolExecutor(max_workers=4) as pool:
        values = dict(pool.map(read, calls))
    for name in ("governor", "guardian", "treasury", "backstop"):
        if values[name] != int(manifest[name], 16):
            raise ProbeError(f"Live {name} does not match the deployment manifest")
    if values["token"] != int(manifest["usdc"], 16) or values["factoryRegistered"] != 1:
        raise ProbeError("Live collateral or factory registration is wrong")
    for name in ("governor", "guardian", "treasury", "backstop", "token"):
        values[name] = "0x" + format(values[name], "040x")
    result = {"chainId": 10143, "block": int(block, 16), "hash": header["hash"],
              "timestamp": int(header["timestamp"], 16), **values}
    if values["adapterReadyAt"]:
        result["adapterReadyUtc"] = datetime.fromtimestamp(values["adapterReadyAt"], timezone.utc).isoformat()
    result["reserveFunded"] = values["reserveWad"] >= 10_000 * 10**18
    (FOLDER / "testnet-status.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("deploy", "configure", "activate", "status"))
    parser.add_argument("--broadcast", action="store_true", help="Submit the simulated stage on chain 10143")
    parser.add_argument("--verify-only", action="store_true", help="Recheck existing receipts without signing or sending")
    args = parser.parse_args()
    env, endpoint = testnet_env()
    if args.stage == "status":
        if args.broadcast or args.verify_only:
            raise ProbeError("Status is read-only and needs no execution flags")
        status(endpoint)
        return
    live_path = FOLDER / f"testnet-{args.stage}-receipts.json"
    if args.verify_only:
        if args.broadcast:
            raise ProbeError("Verification cannot broadcast")
        verify_stage(endpoint, args.stage, live_path)
        return
    signer = wallet(env)
    if not signer["signerConfigured"]:
        raise ProbeError("Configure a funded testnet signing key before executing deployment stages")
    sender = signer["address"]
    env.update(DEPLOYER=sender, DEPLOY_CONFIG="reports/deployment/testnet-config.json",
               DEPLOY_OUTPUT="reports/deployment/testnet-manifest.json")
    FOLDER.mkdir(parents=True, exist_ok=True)
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
        if live_path.exists():
            raise ProbeError("A stage journal exists; verify or reconcile it before any retry")
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
    verify_stage(endpoint, args.stage, live_path)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
