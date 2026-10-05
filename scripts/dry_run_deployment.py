#!/usr/bin/env python3
"""Rehearse deployments on a pinned mainnet fork. No signing or broadcast option exists here."""
import json
import subprocess

from monad_preflight import ROOT, ProbeError, load_env, rpc
from run_monad_fork import redact_output


def creation_summary(manifest, broadcast):
    transactions = broadcast.get("transactions", [])
    addresses = {item.get("contractAddress", "").lower() for item in transactions}
    expected = {address.lower() for address in manifest["contracts"]}
    if len(transactions) != 19 or len(expected) != 19 or addresses != expected or broadcast.get("receipts"):
        raise ProbeError("Creation output does not match the 19-contract dry-run manifest")
    result = []
    for item in transactions:
        if item["transactionType"] not in ("CREATE", "CREATE2"):
            raise ProbeError("Unexpected transaction in creation rehearsal")
        result.append({"contract": item["contractName"], "address": item["contractAddress"],
                       "simulatedGasLimit": int(item["transaction"]["gas"], 16)})
    return result


def main():
    env = load_env()
    endpoint = env.get("ALCHEMY_MONAD_RPC")
    if not endpoint:
        raise SystemExit("Set ALCHEMY_MONAD_RPC in .env")
    report = json.loads((ROOT / "reports/monad/preflight.json").read_text())
    if report.get("chainId") != 143:
        raise SystemExit("Expected a Monad mainnet preflight")
    anchor = report["governanceFork"]
    try:
        if int(rpc(endpoint, "eth_chainId", []), 16) != 143:
            raise ProbeError("RPC chain does not match the rehearsal")
        for pinned in (anchor, report["updateFork"]):
            header = rpc(endpoint, "eth_getBlockByNumber", [hex(pinned["block"]), False])
            if not header or header["hash"] != pinned["hash"]:
                raise ProbeError("Pinned block hash changed; refresh preflight")
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None

    folder = ROOT / "reports/deployment"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "rehearsal.json").write_text(json.dumps({"status": "incomplete", "broadcast": False}) + "\n")
    network = json.loads((ROOT / "config/monad-mainnet.json").read_text())
    config = {
        "chainId": 143, "usdc": network["usdc"], "pythCore": network["pythCore"],
        "governor": "0x0000000000000000000000000000000000001001",
        "guardian": "0x0000000000000000000000000000000000001002",
        "treasury": "0x0000000000000000000000000000000000001003",
        "maxUpdateAgeSeconds": 3, "blockTimeMillis": 300, "slashToReserve": True,
    }
    (folder / "fork-config.json").write_text(json.dumps(config, indent=2) + "\n")
    env.update(
        DEPLOY_CONFIG="reports/deployment/fork-config.json",
        DEPLOY_OUTPUT="reports/deployment/fork-manifest.json",
        DEPLOYER="0x000000000000000000000000000000000000beef",
        FOUNDRY_PROFILE="monad", MONAD_FORK_ENABLED="true",
    )
    commands = [
        ["forge", "script", "script/DeployPripo.s.sol:DeployPripo", "--rpc-url", "monad",
         "--fork-block-number", str(anchor["block"]), "--sender", env["DEPLOYER"], "-vv"],
        ["forge", "test", "--match-contract", "MonadDeploymentTest", "-vv"],
    ]
    for name, command in zip(("creation", "lifecycle"), commands):
        print(f"Running {name} rehearsal (no broadcast)", flush=True)
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        output = redact_output(result.stdout, env)
        (folder / f"{name}.log").write_text(output)
        print(output, end="", flush=True)
        if result.returncode:
            raise SystemExit(result.returncode)
    try:
        transactions = creation_summary(
            json.loads((folder / "fork-manifest.json").read_text()),
            json.loads((ROOT / "broadcast/DeployPripo.s.sol/143/dry-run/run-latest.json").read_text()),
        )
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
    summary = {
        "status": "passed", "mode": "local-fork-only", "broadcast": False, "chainId": 143,
        "creationFork": anchor, "signedUpdateFork": report["updateFork"],
        "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "workingTreeDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)),
        "roles": "synthetic rehearsal addresses", "estimatedGasSource": "Foundry EVM simulation",
        "creations": transactions, "totalSimulatedGasLimit": sum(t["simulatedGasLimit"] for t in transactions),
        "submittedGasLimit": None, "chargedGas": None, "chargedFee": None,
    }
    (folder / "rehearsal.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Rehearsal complete. Outputs are in reports/deployment; no transactions were submitted.")


if __name__ == "__main__":
    main()
