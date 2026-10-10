#!/usr/bin/env python3
"""Rehearse committed deployment scripts on the recorded isolated Tenderly fork."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import io
import hashlib
import json
import shutil
import subprocess
import tarfile
import time

from deploy_testnet import created_address, keccak, receipt_cost
from dry_run_deployment import creation_summary
from mock_testnet import calldata
from monad_preflight import ROOT, ProbeError, load_env, request_json, rpc
from run_monad_fork import redact_output
from tenderly_environment import CHAIN_ID, JOURNAL, SENDER, admin_rpc, environment_parts, require_chain_domain
from tenderly_stage import project_api

FOLDER = ROOT / "reports/deployment/tenderly"
SOURCE = FOLDER / "source"
SAFE_FACTORY = "0x4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67"
STAGES = {"safes": ("RehearsalSafes.s.sol", "CreateRehearsalSafes", 4),
          "deploy": ("DeployPripo.s.sol", "DeployPripo", 19),
          "configure": ("RehearsalSafes.s.sol", "ConfigureRehearsalSafes", 3)}


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def read(name):
    return json.loads((FOLDER / name).read_text())


def context():
    env = load_env()
    record = json.loads(JOURNAL.read_text())
    if (record.get("status") != "verified" or record["account"] != env["TENDERLY_ACCOUNT_SLUG"]
            or record["project"] != env["TENDERLY_PROJECT_SLUG"]):
        raise ProbeError("Verify the intended environment first")
    current = project_api(env, "/environments/" + record["environmentId"], public=True)
    instance, vnet, endpoint = environment_parts(current, record)
    if (instance["id"] != record["instanceId"] or vnet["id"] != record["vnetId"]
            or endpoint != env.get("TENDERLY_RPC") or vnet.get("sync_state_config", {}).get("enabled") is not False
            or int(rpc(endpoint, "eth_chainId", []), 16) != CHAIN_ID):
        raise ProbeError("Rehearsal instance, RPC, chain or disabled-sync check failed")
    require_chain_domain(endpoint)
    FOLDER.mkdir(parents=True, exist_ok=True)
    return env, endpoint, record


def call(endpoint, address, signature, *args):
    return rpc(endpoint, "eth_call", [{"to": address, "data": calldata(signature, *args)}, "latest"])


def uint(endpoint, address, signature, *args):
    return int(call(endpoint, address, signature, *args), 16)


def prepare_source(folder=FOLDER):
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / "source"
    path = folder / "source.json"
    if path.exists():
        return json.loads(path.read_text())
    if source.exists():
        raise ProbeError("Incomplete source extraction; inspect before retrying")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    archive = subprocess.check_output(["git", "archive", commit, "src", "script", "config", "foundry.toml",
                                       "remappings.txt"], cwd=ROOT)
    source.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        bundle.extractall(source, filter="data")
    deps = {}
    for name in ("forge-std", "openzeppelin-contracts"):
        dep = source / "lib" / name
        shutil.copytree(ROOT / "lib" / name, dep, ignore=shutil.ignore_patterns(".git"))
        digest = hashlib.sha256()
        for file in sorted(p for p in dep.rglob("*") if p.is_file()):
            digest.update(str(file.relative_to(dep)).encode() + b"\0")
            digest.update(hashlib.sha256(file.read_bytes()).digest())
        deps[name] = {"treeSha256": digest.hexdigest()}
    (source / "reports/deployment").mkdir(parents=True)
    record = {"commit": commit, "dependencies": deps, "workingTreeEditsIncluded": False}
    save(path, record)
    return record


def verified_receipts(endpoint, items):
    def verify_item(item):
        tx_hash = item.get("hash")
        if not tx_hash:
            raise ProbeError("Missing submitted hash; inspect Foundry broadcast before retrying")
        receipt = None
        for _ in range(10):
            receipt = rpc(endpoint, "eth_getTransactionReceipt", [tx_hash])
            if receipt:
                break
            time.sleep(1)
        if receipt is None:
            raise ProbeError("Receipt not yet available; verify without resubmission")
        tx = rpc(endpoint, "eth_getTransactionByHash", [tx_hash])
        if tx["from"].lower() != SENDER.lower():
            raise ProbeError("Unexpected rehearsal sender")
        cost = receipt_cost(tx, receipt)
        if item.get("transactionType") in ("CREATE", "CREATE2"):
            cost["createdAddress"] = created_address(item, tx, receipt)
        return cost
    with ThreadPoolExecutor(max_workers=6) as pool:
        return list(pool.map(verify_item, items))


def state(endpoint):
    cfg = read("config.json")
    def safe_state(spec):
        role, count, threshold = spec
        address = cfg[role]
        raw = call(endpoint, address, "getOwners()")[2:]
        owners = ["0x" + raw[i + 24:i + 64] for i in range(128, len(raw), 64)]
        actual = uint(endpoint, address, "getThreshold()")
        if len(owners) != count or len(set(owners)) != count or actual != threshold:
            raise ProbeError("Invalid rehearsal Safe owners/threshold: " + role)
        return role, {"address": address, "owners": owners, "threshold": actual,
                      "nonce": uint(endpoint, address, "nonce()")}
    with ThreadPoolExecutor(max_workers=4) as pool:
        safes = dict(pool.map(safe_state, (("governor", 5, 3), ("guardian", 3, 2), ("treasury", 5, 3), ("council", 5, 3))))
    result = {"safes": safes}
    if (FOLDER / "manifest.json").exists():
        m = read("manifest.json")
        def check_code(pair):
            address, expected = pair
            if keccak(rpc(endpoint, "eth_getCode", [address, "latest"])).lower() != expected.lower():
                raise ProbeError("Runtime differs from deployment manifest")
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(check_code, zip(m["contracts"], m["runtimeCodeHashes"])))
        result.update(vault=m["vault"], factory=m["factory"],
                      backstop="0x" + format(uint(endpoint, m["vault"], "backstopController()"), "040x"),
                      factoryRegistered=bool(uint(endpoint, m["vault"], "registrars(address)", m["factory"])),
                      adapterReadyAt=uint(endpoint, m["factory"], "adapterReadyAt(address)", m["pythAdapter"]),
                      reserveWad=str(uint(endpoint, m["vault"], "protocolReserve()")),
                      vaultUsdc=str(uint(endpoint, m["usdc"], "balanceOf(address)", m["vault"])))
    save(FOLDER / "status.json", result)
    return result


def verify_stage(endpoint, stage, record):
    if stage in STAGES:
        filename, _, count = STAGES[stage]
        saved = FOLDER / (stage + "-broadcast.json")
        if not saved.exists():
            saved.write_text((SOURCE / f"broadcast/{filename}/{CHAIN_ID}/run-latest.json").read_text())
        items = json.loads(saved.read_text())["transactions"]
        if len(items) != count:
            raise ProbeError("Incomplete stage transaction count")
        record["transactions"] = verified_receipts(endpoint, items)
        for filename in ("config.json", "manifest.json"):
            local = SOURCE / "reports/deployment" / filename
            if local.exists():
                (FOLDER / filename).write_text(local.read_text())
        record["state"] = state(endpoint)
        if stage == "deploy":
            created = {c["createdAddress"].lower() for c in record["transactions"]}
            if created != {a.lower() for a in read("manifest.json")["contracts"]}:
                raise ProbeError("Deployment receipts do not cover the manifest")
        if stage == "configure":
            s, m = record["state"], read("manifest.json")
            if (not s["factoryRegistered"] or s["backstop"].lower() != m["backstop"].lower()
                    or not s["adapterReadyAt"] or s["safes"]["governor"]["nonce"] != 3):
                raise ProbeError("Governance wiring mismatch")
    elif stage == "fund":
        usdc = record["usdc"]
        record["nativeBalanceWei"] = str(int(rpc(endpoint, "eth_getBalance", [SENDER, "latest"]), 16))
        record["usdcBalance"] = str(uint(endpoint, usdc, "balanceOf(address)", SENDER))
        if int(record["nativeBalanceWei"]) != 1000 * 10**18 or int(record["usdcBalance"]) != 100_000 * 10**6:
            raise ProbeError("Fork balance overrides did not take effect")
    elif stage == "reserve":
        record["transactions"] = verified_receipts(endpoint, record["submitted"])
        record["state"] = state(endpoint)
        if (int(record["state"]["reserveWad"]) != 10_000 * 10**18
                or int(record["state"]["vaultUsdc"]) != 10_000 * 10**6):
            raise ProbeError("Reserve is not fully cash-backed")
    record.update(status="verified", verifiedAt=datetime.now(timezone.utc).isoformat())
    save(FOLDER / (stage + ".json"), record)
    print(json.dumps(record, indent=2))


def forge(stage, env, execute):
    if stage == "configure" and not execute:
        manifest = read("manifest.json")
        zero = "0x" + "00" * 20
        data = calldata("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                        manifest["governanceTargets"][0], 0, manifest["governanceCalldata"][0],
                        0, 0, 0, 0, zero, zero, "0x")
        header = rpc(env["TENDERLY_RPC"], "eth_getBlockByNumber", ["latest", False])
        result = request_json(env["TENDERLY_RPC"], {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                              "params": [{"from": SENDER, "to": manifest["governor"], "data": data}, header["number"]]},
                              {"Content-Type": "application/json"})
        error = json.dumps(result.get("error", {}))
        if "GS020" not in error and calldata("Error(string)", "GS020")[2:] not in error:
            raise ProbeError("Governor did not return the expected insufficient-signatures rejection")
        save(FOLDER / "governor-rejection.json", {"block": int(header["number"], 16), "hash": header["hash"],
             "governor": manifest["governor"], "signatures": 0, "required": 3, "revertReason": "GS020",
             "submitted": False})
    filename, contract, count = STAGES[stage]
    command = ["forge", "script", f"script/{filename}:{contract}", "--rpc-url", "tenderly", "--sender", SENDER,
               "--slow", "-vv"]
    if execute:
        command += ["--broadcast", "--unlocked"]
    process_env = dict(env, DEPLOYER=SENDER, REHEARSAL_SAFE_SALT="1", FOUNDRY_PROFILE="default",
                       DEPLOY_CONFIG="reports/deployment/config.json", DEPLOY_OUTPUT="reports/deployment/manifest.json")
    for name in ("FUNDED_DEPLOYER_PRIVATE_KEY", "TENDERLY_ACCESS_KEY", "PYTH_API_KEY"):
        process_env.pop(name, None)
    result = subprocess.run(command, cwd=SOURCE, env=process_env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = redact_output(result.stdout, env)
    label = stage + ("-broadcast" if execute else "-simulation")
    (FOLDER / (label + ".log")).write_text(output)
    print(output, flush=True)
    if result.returncode:
        raise ProbeError("Foundry stage failed; inspect saved output and journal before retrying")
    if not execute:
        plan = json.loads((SOURCE / f"broadcast/{filename}/{CHAIN_ID}/dry-run/run-latest.json").read_text())
        if len(plan["transactions"]) != count:
            raise ProbeError("Unexpected simulated transaction count")
        if stage == "deploy":
            creation_summary(json.loads((SOURCE / "reports/deployment/manifest.json").read_text()), plan)
        else:
            target = SAFE_FACTORY if stage == "safes" else read("config.json")["governor"].lower()
            if any(t["transaction"].get("to", "").lower() != target for t in plan["transactions"]):
                raise ProbeError("Unexpected rehearsal call target")
        save(FOLDER / (stage + "-plan.json"), plan)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("fund", "safes", "deploy", "configure", "reserve", "status"))
    flags = parser.add_mutually_exclusive_group()
    flags.add_argument("--execute", action="store_true")
    flags.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    env, endpoint, environment = context()
    if args.stage == "status":
        print(json.dumps(state(endpoint), indent=2))
        return
    path = FOLDER / (args.stage + ".json")
    if args.verify_only:
        record = read(args.stage + ".json")
        if record["environmentId"] != environment["environmentId"] or record["instanceId"] != environment["instanceId"]:
            raise ProbeError("Journal belongs to another fork")
        verify_stage(endpoint, args.stage, record)
        return
    if path.exists():
        raise ProbeError("Stage journal exists; verify or reconcile without resubmitting")
    previous = {"safes": "fund", "deploy": "safes", "configure": "deploy", "reserve": "configure"}.get(args.stage)
    if previous and read(previous + ".json")["status"] != "verified":
        raise ProbeError("Previous stage must be verified")
    source = prepare_source()
    record = {"status": "incomplete", "stage": args.stage, "chainId": CHAIN_ID, "sender": SENDER,
              "environmentId": environment["environmentId"], "instanceId": environment["instanceId"],
              "source": source, "startedAt": datetime.now(timezone.utc).isoformat(), "productionReady": False}
    if args.stage in STAGES:
        forge(args.stage, env, False)
    if not args.execute:
        print("Plan only; no fork mutations submitted.")
        return
    save(path, record)
    if args.stage == "fund":
        record["usdc"] = environment["dependencies"]["usdc"]["address"]
        record["balanceOverrides"] = []
        save(path, record)
        for method, params in (("tenderly_setBalance", [SENDER, hex(1000 * 10**18)]),
                               ("tenderly_setErc20Balance", [record["usdc"], SENDER, hex(100_000 * 10**6)])):
            result = admin_rpc(endpoint, method, params)
            record["balanceOverrides"].append({"method": method, "params": params, "result": result})
            save(path, record)
    elif args.stage in STAGES:
        forge(args.stage, env, True)
    elif args.stage == "reserve":
        m = read("manifest.json")
        if uint(endpoint, m["vault"], "protocolReserve()") != 0:
            raise ProbeError("Reserve already funded; inspect before contributing again")
        record["submitted"] = []
        for target, data in ((m["usdc"], calldata("approve(address,uint256)", m["vault"], str(10_000 * 10**6))),
                             (m["vault"], calldata("fundProtocolReserve(uint256)", str(10_000 * 10**6)))):
            tx = {"from": SENDER, "to": target, "data": data, "value": "0x0"}
            gas = int(rpc(endpoint, "eth_estimateGas", [tx]), 16)
            tx.update(gas=hex(gas * 13 // 10), gasPrice=rpc(endpoint, "eth_gasPrice", []))
            tx_hash = admin_rpc(endpoint, "eth_sendTransaction", [tx])
            record["submitted"].append({"hash": tx_hash})
            save(path, record)
            verified_receipts(endpoint, [{"hash": tx_hash}])
    verify_stage(endpoint, args.stage, record)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
