#!/usr/bin/env python3
"""Create and verify one isolated Monad-mainnet rehearsal environment; never deploy on a public chain."""
import argparse
from datetime import datetime, timezone
import json
import re
import subprocess
from urllib.parse import urlsplit

from deploy_testnet import keccak
from monad_preflight import ROOT, ProbeError, load_env, request_json, rpc
from tenderly_stage import ProjectAPIError, project_api, project_status

FOLDER = ROOT / "reports/tenderly"
JOURNAL = FOLDER / "environment.json"
SENDER = "0x00000000000000000000000000000000000A11cE"
CHAIN_ID = 999143


def number(value):
    return int(value, 16 if value.startswith("0x") else 10) if isinstance(value, str) else int(value)


def create_payload(header):
    return {"display_name": "Pripo Monad mainnet rehearsal", "slug": "pripo-rehearsal-20261009",
            "network_configs": [{"network_id": "143", "block_number": header["number"],
                                  "chain_config_overrides": {"chain_id": str(CHAIN_ID)},
                                  "accounts": [{"address": SENDER, "balance": hex(1000 * 10**18)}],
                                  "explorer_config": {"enabled": False, "contract_verification_visibility": "abi"}}],
            "bridge_config": {"enabled": False, "relay_mode": "autoRelay", "delay_seconds": 0}}


def environment_parts(result, record):
    instance = result.get("active_instance") or {}
    vnets = instance.get("vnets", [])
    if result.get("slug") != record["request"]["slug"] or len(vnets) != 1:
        raise ProbeError("Expected the recorded single-network rehearsal")
    vnet = vnets[0]
    fork = vnet.get("fork_config", {})
    chain = vnet.get("virtual_network_config", {}).get("chain_config", {})
    if (number(fork.get("network_id", 0)) != 143 or number(chain.get("chain_id", 0)) != CHAIN_ID
            or number(fork.get("block_number", 0)) != record["parent"]["block"]):
        raise ProbeError("Environment ancestry or isolated chain ID does not match the plan")
    endpoints = [r["url"] for r in vnet.get("rpcs", []) if r.get("name", "").lower() == "admin rpc"]
    if len(endpoints) != 1:
        raise ProbeError("Expected exactly one Admin RPC")
    parsed = urlsplit(endpoints[0])
    if (parsed.scheme != "https" or not (parsed.hostname or "").endswith(".rpc.tenderly.co")
            or parsed.username or parsed.password or not re.fullmatch(r"https://[A-Za-z0-9./_?&=%:-]+", endpoints[0])):
        raise ProbeError("Unexpected Admin RPC destination")
    return instance, vnet, endpoints[0]


def save_rpc(endpoint):
    path = ROOT / ".env"
    content = path.read_text()
    pattern = r"^\s*(?:export\s+)?TENDERLY_RPC\s*=.*$"
    line = 'TENDERLY_RPC="' + endpoint + '"'
    if re.search(pattern, content, re.M):
        content = re.sub(pattern, lambda _: line, content, flags=re.M)
    else:
        content = content.rstrip() + "\n" + line + "\n"
    path.write_text(content)
    path.chmod(0o600)


def admin_rpc(endpoint, method, params):
    if int(rpc(endpoint, "eth_chainId", []), 16) != CHAIN_ID:
        raise ProbeError("Admin RPC requires isolated rehearsal chain 999143")
    if method not in ("tenderly_stopSync", "tenderly_getSyncStatus", "tenderly_setBalance",
                      "tenderly_setErc20Balance", "eth_sendTransaction", "evm_snapshot", "evm_revert",
                      "evm_increaseTime", "evm_increaseBlocks", "evm_setNextBlockTimestamp"):
        raise ProbeError("Unsupported rehearsal RPC method")
    result = request_json(endpoint, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                          {"Content-Type": "application/json"})
    if "error" in result:
        raise ProbeError(f"Rehearsal {method} RPC error {result['error'].get('code')}")
    return result.get("result")


def verify(env, record):
    if record.get("account") != env["TENDERLY_ACCOUNT_SLUG"] or record.get("project") != env["TENDERLY_PROJECT_SLUG"]:
        raise ProbeError("Environment journal belongs to another project")
    if record.get("environmentId"):
        result = project_api(env, "/environments/" + record["environmentId"], public=True)
    else:
        matches = [e for e in project_api(env, "/environments", public=True)
                   if e.get("slug") == record["request"]["slug"]]
        if len(matches) != 1:
            raise ProbeError("Cannot reconcile creation; inspect the journal without resubmitting")
        result = matches[0]
    instance, vnet, endpoint = environment_parts(result, record)
    record.update(environmentId=result["id"], instanceId=instance["id"], vnetId=vnet["id"])
    JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
    if int(rpc(endpoint, "eth_chainId", []), 16) != CHAIN_ID:
        raise ProbeError("RPC chain differs from rehearsal metadata")
    parent = rpc(env["ALCHEMY_MONAD_RPC"], "eth_getBlockByNumber", [hex(record["parent"]["block"]), False])
    if parent["hash"] != record["parent"]["hash"]:
        raise ProbeError("Pinned mainnet block hash changed")
    save_rpc(endpoint)
    cfg = json.loads((ROOT / "config/monad-mainnet.json").read_text())
    dependencies = {}
    for label, address in (("usdc", cfg["usdc"]), ("pythCore", cfg["pythCore"]),
                           ("safeSingleton", "0x41675C099F32341bf84BFc5382aF534df5C7461a"),
                           ("safeFactory", "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")):
        source = rpc(env["ALCHEMY_MONAD_RPC"], "eth_getCode", [address, parent["number"]])
        actual = rpc(endpoint, "eth_getCode", [address, "latest"])
        if actual == "0x" or actual.lower() != source.lower():
            raise ProbeError(f"Fork {label} differs from pinned mainnet code")
        dependencies[label] = {"address": address, "runtimeCodeHash": keccak(actual)}
    decimals = int(rpc(endpoint, "eth_call", [{"to": cfg["usdc"], "data": "0x313ce567"}, "latest"]), 16)
    if decimals != 6:
        raise ProbeError("Fork USDC decimals mismatch")
    record.update(status="verified", verifiedAt=datetime.now(timezone.utc).isoformat(), chainId=CHAIN_ID,
                  dependencies=dependencies, usdcDecimals=decimals, syncState=vnet.get("sync_state_config"),
                  sender=SENDER, nativeBalanceWei=str(int(rpc(endpoint, "eth_getBalance", [SENDER, "latest"]), 16)),
                  rpcSavedToIgnoredEnv=True, productionReady=False)
    JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    flags = parser.add_mutually_exclusive_group()
    flags.add_argument("--create", action="store_true")
    flags.add_argument("--verify-only", action="store_true")
    flags.add_argument("--retry-rejected", action="store_true", help="Retry an explicitly rejected request after checking for an existing fork")
    args = parser.parse_args()
    env = load_env()
    FOLDER.mkdir(parents=True, exist_ok=True)
    if args.verify_only:
        verify(env, json.loads(JOURNAL.read_text()))
        return
    if args.retry_rejected:
        previous = json.loads(JOURNAL.read_text())
        if previous.get("status") != "rejected":
            raise ProbeError("Only an explicitly rejected request can be retried")
        attempts = FOLDER / "environment-rejected-attempts.json"
        history = json.loads(attempts.read_text()) if attempts.exists() else []
        history.append(previous)
        attempts.write_text(json.dumps(history, indent=2) + "\n")
    elif JOURNAL.exists():
        raise ProbeError("Environment journal exists; verify or reconcile without creating another fork")
    status = project_status(env)
    (FOLDER / "project-status.json").write_text(json.dumps(status, indent=2) + "\n")
    source = env.get("ALCHEMY_MONAD_RPC")
    if not source or int(rpc(source, "eth_chainId", []), 16) != 143:
        raise ProbeError("A Monad mainnet source RPC is required")
    header = rpc(source, "eth_getBlockByNumber", ["latest", False])
    payload = create_payload(header)
    if any(e["slug"] == payload["slug"] for e in status["environments"]):
        raise ProbeError("Rehearsal slug already exists; reconcile it before creating anything")
    record = {"status": "planned", "account": env["TENDERLY_ACCOUNT_SLUG"], "project": env["TENDERLY_PROJECT_SLUG"],
              "parent": {"chainId": 143, "block": int(header["number"], 16), "hash": header["hash"],
                         "timestamp": int(header["timestamp"], 16)}, "request": payload,
              "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    (FOLDER / "environment-plan.json").write_text(json.dumps(record, indent=2) + "\n")
    if not (args.create or args.retry_rejected):
        print(json.dumps(record, indent=2))
        return
    record.update(status="creation-started", startedAt=datetime.now(timezone.utc).isoformat())
    JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
    try:
        result = project_api(env, "/environments", public=True, data=payload)
    except ProjectAPIError as exc:
        if exc.status in (400, 401, 403, 404, 422):
            record.update(status="rejected", httpStatus=exc.status, rejection=str(exc))
            JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
        raise
    record["environmentId"] = result["id"]
    JOURNAL.write_text(json.dumps(record, indent=2) + "\n")
    verify(env, record)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
