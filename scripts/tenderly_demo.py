#!/usr/bin/env python3
"""Deploy the authorized single-account demo on the authenticated Tenderly fork."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import subprocess

from deploy_testnet import keccak
from deploy_tenderly import prepare_source, save, verified_receipts
from mock_testnet import calldata
from monad_preflight import ROOT, ProbeError, load_env, rpc
from run_monad_fork import redact_output
from tenderly_environment import CHAIN_ID, JOURNAL, SENDER, chain_domain, environment_parts, save_rpc
from tenderly_stage import project_api

FOLDER = ROOT / "reports/deployment/tenderly-demo"
SOURCE = FOLDER / "source"
ORIGINAL = ROOT / "reports/deployment/tenderly/manifest.json"
STAGES = {"deploy": "DeployTenderlyDemo", "fund": "FundTenderlyDemo", "market": "CreateTenderlyDemoMarket"}
SYMBOL = "PRIPO:DEMO"
PRICE, DEPTH, SEED = 100 * 10**18, 200_000 * 10**18, 2_000 * 10**6


def read(name):
    return json.loads((FOLDER / name).read_text())


def validate_domain(domain):
    # Explicit user choice: direct account governance on this isolated fork. No Safe or typed signatures.
    if domain["rpcChainId"] != CHAIN_ID or domain["evmChainId"] not in (1, CHAIN_ID):
        raise ProbeError("Unexpected single-account demo network/domain")


def context():
    env = load_env()
    record = json.loads(JOURNAL.read_text())
    if (record["account"] != env["TENDERLY_ACCOUNT_SLUG"] or record["project"] != env["TENDERLY_PROJECT_SLUG"]
            or record.get("status") not in ("verified", "chain-domain-mismatch")):
        raise ProbeError("Expected the recorded, authenticated rehearsal fork")
    current = project_api(env, "/environments/" + record["environmentId"], public=True)
    instance, vnet, endpoint = environment_parts(current, record)
    if (instance["id"] != record["instanceId"] or vnet["id"] != record["vnetId"]
            or vnet.get("sync_state_config", {}).get("enabled") is not False):
        raise ProbeError("Demo fork instance, RPC or sync mode changed")
    domain = chain_domain(endpoint)
    validate_domain(domain)
    # Refresh only from the authenticated API for the exact recorded instance; RPC credentials can rotate.
    if endpoint != env.get("TENDERLY_RPC"):
        save_rpc(endpoint)
        env["TENDERLY_RPC"] = endpoint
    FOLDER.mkdir(parents=True, exist_ok=True)
    proof = {"environmentId": record["environmentId"], "instanceId": record["instanceId"],
             "vnetId": record["vnetId"], "parent": record["parent"], "domain": domain,
             "governanceMode": "single-account", "typedSignatures": False, "productionReady": False}
    path = FOLDER / "environment.json"
    if path.exists() and read("environment.json") != proof:
        raise ProbeError("Recorded demo environment changed; reconcile before proceeding")
    save(path, proof)
    return env, endpoint, proof


def words(endpoint, target, signature, *args, block="latest"):
    result = rpc(endpoint, "eth_call", [{"to": target, "data": calldata(signature, *args)}, block])[2:]
    return [int(result[i:i+64], 16) for i in range(0, len(result), 64)]


def expected_calls(manifest, stage):
    m = manifest
    if stage == "fund":
        return [(m["vault"], calldata("setBackstopController(address)", m["backstop"])),
                (m["vault"], calldata("setRegistrar(address,bool)", m["factory"], "true")),
                (m["usdc"], calldata("approve(address,uint256)", m["vault"], 10_000 * 10**6)),
                (m["vault"], calldata("fundProtocolReserve(uint256)", 10_000 * 10**6))]
    params = f"({SYMBOL},{m['nullAdapter']},0x{'00'*32},{PRICE},{DEPTH},{SEED})"
    return [(m["usdc"], calldata("approve(address,uint256)", m["factory"], SEED)),
            (m["factory"], calldata("createMarket((string,address,bytes32,uint256,uint256,uint256))", params))]


def check_plan(manifest, plan, stage):
    if manifest.get("chainId") != CHAIN_ID or manifest.get("rehearsalOnly") is not True:
        raise ProbeError("Expected an isolated demo manifest")
    if any(manifest[role].lower() != SENDER.lower() for role in ("governor", "guardian", "treasury", "deployer")):
        raise ProbeError("All demo roles must belong to the rehearsal account")
    txs = plan["transactions"]
    if len(txs) != (2 if stage == "market" else 4):
        raise ProbeError("Unexpected demo transaction count")
    for item in txs:
        tx = item["transaction"]
        if tx["from"].lower() != SENDER.lower() or int(tx.get("value", "0x0"), 16) != 0:
            raise ProbeError("Unexpected sender or native transfer")
    if stage == "deploy":
        expected = [manifest[k].lower() for k in ("vault", "backstop", "sweeper", "factory")]
        if [t.get("contractAddress", "").lower() for t in txs] != expected or any(t["transactionType"] != "CREATE" for t in txs):
            raise ProbeError("Expected four separate demo contract creations")
    else:
        for item, (target, data) in zip(txs, expected_calls(manifest, stage)):
            tx = item["transaction"]
            if (item["transactionType"] != "CALL" or tx.get("to", "").lower() != target.lower()
                    or (tx.get("input") or tx.get("data") or "").lower() != data.lower()):
                raise ProbeError("Demo call differs from reviewed target/calldata")


def forge(stage, env, execute):
    command = ["forge", "script", f"script/TenderlyDemo.s.sol:{STAGES[stage]}", "--rpc-url", "tenderly",
               "--sender", SENDER, "--slow", "-vv"]
    if execute:
        command += ["--broadcast", "--unlocked"]
    child = dict(env, DEPLOYER=SENDER, TENDERLY_SINGLE_ACCOUNT_DEMO="true", FOUNDRY_PROFILE="default",
                 DEPLOY_OUTPUT="reports/deployment/" + ("source-manifest.json" if stage == "deploy" else "manifest.json"),
                 DEMO_OUTPUT="reports/deployment/manifest.json", DEMO_MARKET_OUTPUT="reports/deployment/market.json")
    for name in ("FUNDED_DEPLOYER_PRIVATE_KEY", "TENDERLY_ACCESS_KEY", "PYTH_API_KEY"):
        child.pop(name, None)
    result = subprocess.run(command, cwd=SOURCE, env=child, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = redact_output(result.stdout, env)
    (FOLDER / (stage + ("-broadcast.log" if execute else "-simulation.log"))).write_text(output)
    print(output, flush=True)
    if result.returncode:
        raise ProbeError("Demo stage failed; reconcile the journal before any retry")
    path = SOURCE / "broadcast/TenderlyDemo.s.sol" / str(CHAIN_ID)
    if not execute:
        path /= "dry-run"
    plan = json.loads((path / "run-latest.json").read_text())
    manifest = json.loads((SOURCE / "reports/deployment/manifest.json").read_text())
    check_plan(manifest, plan, stage)
    save(FOLDER / (stage + ("-broadcast.json" if execute else "-plan.json")), plan)
    return manifest


def verify(endpoint, stage, proof):
    record = read(stage + ".json")
    if record["environment"] != proof:
        raise ProbeError("Stage journal belongs to another demo environment")
    path = FOLDER / (stage + "-broadcast.json")
    if not path.exists():
        path.write_text((SOURCE / f"broadcast/TenderlyDemo.s.sol/{CHAIN_ID}/run-latest.json").read_text())
    plan = json.loads(path.read_text())
    m = json.loads((SOURCE / "reports/deployment/manifest.json").read_text())
    check_plan(m, plan, stage)
    costs = verified_receipts(endpoint, plan["transactions"])
    def check_transaction(item):
        actual = rpc(endpoint, "eth_getTransactionByHash", [item["hash"]])
        expected = item["transaction"]
        if ((actual.get("to") or "").lower() != (expected.get("to") or "").lower()
                or actual["input"].lower() != (expected.get("input") or expected.get("data") or "").lower()
                or int(actual["value"], 16) != 0):
            raise ProbeError("Submitted transaction differs from the reviewed plan")
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(check_transaction, plan["transactions"]))
    block = hex(max(t["block"] for t in costs))
    original = json.loads(ORIGINAL.read_text())
    for i in (0, 2, 3, 4, *range(8, 19)):
        if m["contracts"][i].lower() != original["contracts"][i].lower():
            raise ProbeError("Unexpected change to a reused implementation")
    def code_check(pair):
        address, expected = pair
        if keccak(rpc(endpoint, "eth_getCode", [address, block])).lower() != expected.lower():
            raise ProbeError("Demo runtime mismatch")
    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(code_check, zip(m["contracts"], m["runtimeCodeHashes"])))
    v, f, token = m["vault"], m["factory"], m["usdc"]
    queries = [("governor", v, "governor()", []), ("guardian", v, "guardian()", []),
               ("treasury", v, "treasury()", []), ("reserveWad", v, "protocolReserve()", []),
               ("vaultUsdc", token, "balanceOf(address)", [v]), ("senderUsdc", token, "balanceOf(address)", [SENDER]),
               ("registrar", v, "registrars(address)", [f]), ("backstop", v, "backstopController()", []),
               ("marketCount", f, "marketCount()", [])]
    def query(item):
        key, target, sig, args = item
        return key, words(endpoint, target, sig, *args, block=block)[0]
    with ThreadPoolExecutor(max_workers=6) as pool:
        state = dict(pool.map(query, queries))
    if any(state[role] != int(SENDER, 16) for role in ("governor", "guardian", "treasury")):
        raise ProbeError("Incorrect live demo roles")
    if stage != "deploy":
        if state["registrar"] != 1 or state["backstop"] != int(m["backstop"], 16) or state["reserveWad"] != 10_000 * 10**18:
            raise ProbeError("Demo governance or reserve setup is incomplete")
        if state["vaultUsdc"] != (12_000 if stage == "market" else 10_000) * 10**6:
            raise ProbeError("Demo cash does not match reserve and seed")
    if stage == "market":
        market = json.loads((SOURCE / "reports/deployment/market.json").read_text())
        a = market["market"]
        checks = [(f, "predictAddress(string)", [int(a, 16)], [SYMBOL]),
                  (f, "marketForSymbol(bytes32)", [int(a, 16)], [keccak(SYMBOL)]),
                  (f, "isMarket(address)", [1], [a]), (a, "vault()", [int(v, 16)], []),
                  (a, "externalIndex()", [0], []), (a, "markPrice()", [PRICE], []),
                  (a, "positionCount()", [0], []), (a, "marginEntryVersion()", [1], []),
                  (a, "openInterest()", [0, 0, 20_000 * 10**18], []),
                  (v, "ledger(address)", [0, 0, SEED * 10**12, 0, 0, 0], [a]),
                  (v, "requireOpenAllowed(address)", [], [a]),
                  (token, "allowance(address,address)", [0], [SENDER, f])]
        def check(item):
            target, sig, expected, args = item
            if words(endpoint, target, sig, *args, block=block) != expected:
                raise ProbeError("Market check failed: " + sig)
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(check, checks))
        code = rpc(endpoint, "eth_getCode", [a, block])
        expected = "0x363d3d373d3d3d363d73" + m["marketImplementation"][2:] + "5af43d82803e903d91602b57fd5bf3"
        if code.lower() != expected.lower() or state["marketCount"] != 1:
            raise ProbeError("Incorrect demo clone or market count")
        state.update(market=a, symbol=SYMBOL, opensAllowed=True, insuranceWad=SEED * 10**12, markPriceWad=PRICE)
        save(FOLDER / "market.json", market)
    save(FOLDER / "manifest.json", m)
    record.update(status="verified", transactions=costs, state=state, verifiedAt=datetime.now(timezone.utc).isoformat())
    save(FOLDER / (stage + ".json"), record)
    print(json.dumps({"stage": stage, "status": "verified", "transactions": len(costs), "vault": v, "factory": f,
                      "state": {k:state[k] for k in state if k not in ("governor", "guardian", "treasury", "backstop")}}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=STAGES)
    flags = parser.add_mutually_exclusive_group()
    flags.add_argument("--execute", action="store_true")
    flags.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    env, endpoint, proof = context()
    if args.verify_only:
        verify(endpoint, args.stage, proof)
        return
    journal = FOLDER / (args.stage + ".json")
    if journal.exists():
        raise ProbeError("Stage journal exists; verify or reconcile without resubmitting")
    previous = {"fund": "deploy", "market": "fund"}.get(args.stage)
    if previous and read(previous + ".json")["status"] != "verified":
        raise ProbeError("Previous demo stage must be verified")
    source = prepare_source(FOLDER)
    target = SOURCE / "reports/deployment/source-manifest.json"
    if not target.exists():
        target.write_text(ORIGINAL.read_text())
    forge(args.stage, env, False)
    if not args.execute:
        print("Simulation only; no transaction submitted.")
        return
    # Recheck the authenticated destination immediately before submitting the reviewed simulation.
    _, _, current = context()
    if current != proof:
        raise ProbeError("Demo environment changed during simulation")
    save(journal, {"status": "incomplete", "stage": args.stage, "environment": proof, "source": source,
                   "startedAt": datetime.now(timezone.utc).isoformat()})
    forge(args.stage, env, True)
    verify(endpoint, args.stage, proof)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
