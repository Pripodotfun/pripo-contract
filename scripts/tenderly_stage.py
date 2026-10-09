#!/usr/bin/env python3
"""Verify Tenderly network support and prepare ABI-derived monitoring plans without broadcasting."""
import argparse
from datetime import datetime, timezone
import json
import re
import subprocess
import urllib.error
import urllib.request
from urllib.parse import quote

from monad_preflight import ROOT, NoRedirect, ProbeError, load_env, request_json, rpc
from run_monad_fork import redact_output

REGISTRY = "https://api.tenderly.co/api/v1/supported-networks"
EVENTS = {
    "BadDebt": ("Market", "market"),
    "StatusChanged": ("Market", "market"),
    "DeficitChanged": ("MarginVault", "vault"),
    "ForcedSettlement": ("Market", "market"),
}


class ProjectAPIError(ProbeError):
    def __init__(self, status, detail):
        self.status = status
        super().__init__(f"Tenderly HTTP {status}: {detail}")


def project_api(env, path, public=False, data=None):
    account, project = env.get("TENDERLY_ACCOUNT_SLUG"), env.get("TENDERLY_PROJECT_SLUG")
    key = env.get("TENDERLY_ACCESS_KEY")
    if not key or not account or not project:
        raise ProbeError("Set the Tenderly access key and account/project slugs")
    prefix = "https://api.tenderly.co/api/" + ("public/" if public else "") + "v1"
    base = prefix + "/account/" + quote(account, safe="") + "/project/" + quote(project, safe="")
    request = urllib.request.Request(base + path, None if data is None else json.dumps(data).encode(),
                                     {"X-Access-Key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read(4096).decode(errors="replace")
        # Provider validation messages are useful, but may echo keys or URLs.
        detail = re.sub(r"https?://[^\s\"<>]+", "[URL REDACTED]", redact_output(body, env))
        raise ProjectAPIError(exc.code, detail[:1500]) from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ProbeError(f"Tenderly connection failed ({type(exc).__name__})") from None
    except (ValueError, UnicodeError):
        raise ProbeError("Invalid Tenderly JSON response") from None


def project_status(env):
    account, project = env.get("TENDERLY_ACCOUNT_SLUG"), env.get("TENDERLY_PROJECT_SLUG")
    if not account or not project or not env.get("TENDERLY_ACCESS_KEY"):
        raise ProbeError("Set the Tenderly access key and account/project slugs")
    # Virtual-environment access is independent of project-metadata permission.
    metadata = {}
    metadata_error = None
    try:
        metadata = project_api(env, "").get("project", {})
    except ProbeError as exc:
        metadata_error = str(exc)
    try:
        environments = project_api(env, "/environments", public=True)
    except ProbeError as exc:
        raise ProbeError(f"Tenderly environment list: {exc}") from None
    if not isinstance(environments, list):
        raise ProbeError("Unexpected environment-list response")
    # Environment responses include Admin RPC URLs. Retain only non-credential metadata.
    summaries = []
    for item in environments:
        instance = item.get("active_instance") or {}
        summaries.append({"id": item.get("id"), "slug": item.get("slug"),
                          "displayName": item.get("display_name"), "createdAt": item.get("created_at"),
                          "instanceId": instance.get("id"), "networks": [
                              {"id": n.get("id"), "networkId": n.get("network_id"),
                               "blockNumber": n.get("block_number"),
                               "chainConfigOverrides": n.get("chain_config_overrides")}
                              for n in item.get("networks", [])]})
    return {"checkedAt": datetime.now(timezone.utc).isoformat(), "account": account, "project": project,
            "projectId": metadata.get("id"), "permissions": metadata.get("permissions"),
            "projectMetadataError": metadata_error, "environmentAccess": True,
            "environments": summaries}


def monad_support(rows):
    matches = [row for row in rows if str(row.get("chain_id")) == "143"]
    if len(matches) != 1 or matches[0].get("is_testnet") is not False:
        raise ProbeError("Monad mainnet is absent or ambiguous in Tenderly's registry")
    row = matches[0]
    for feature in ("virtual_testnet", "monitoring", "simulator", "explorer"):
        if row.get("supported_features", {}).get(feature) is not True:
            raise ProbeError(f"Tenderly does not report Monad support for {feature}")
    return row


def address(value):
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise ProbeError("Expected a nonzero public contract address")
    return value.lower()


def event_definitions():
    result = []
    for name, (contract, target) in EVENTS.items():
        abi = json.loads((ROOT / "abi" / f"{contract}.json").read_text())
        matches = [item for item in abi if item.get("type") == "event" and item.get("name") == name]
        if len(matches) != 1:
            raise ProbeError(f"Expected exactly one {name} event in the runtime ABI")
        event = matches[0]
        signature = name + "(" + ",".join(item["type"] for item in event["inputs"]) + ")"
        topic = subprocess.check_output(["cast", "keccak", signature], cwd=ROOT, text=True).strip()
        result.append({"name": name, "target": target, "signature": signature, "topic0": topic,
                       "abi": event})
    return result


def alert_payloads(definitions, network_id, vault, markets, channel):
    """Each market has its own emitter filter; implementation/library addresses never stand in for clones."""
    if not network_id or not channel:
        raise ProbeError("Alert network ID and delivery channel ID are required")
    vault = address(vault)
    markets = [address(item) for item in markets]
    if not markets or len(markets) != len(set(markets)) or vault in markets:
        raise ProbeError("Provide distinct deployed market clone addresses")
    result = []
    for event in definitions:
        targets = [vault] if event["target"] == "vault" else markets
        for target in targets:
            result.append({
                "name": f"Pripo {event['name']} {network_id} {target}",
                "description": event["signature"], "simple_type": "log_emitted", "enabled": True,
                "expressions": [
                    {"type": "network", "expression": {"network_id": str(network_id)}},
                    {"type": "emitted_log", "expression": {
                        "address": target, "event_name": event["name"], "event_id": event["topic0"],
                        "decode_events": True,
                    }},
                ],
                "delivery_channels": [{"id": channel, "enabled": True}],
            })
    return result


def check_fork(env):
    endpoint = env.get("TENDERLY_RPC")
    if not endpoint:
        raise ProbeError("Set TENDERLY_RPC to the Virtual TestNet RPC")
    if int(rpc(endpoint, "eth_chainId", []), 16) != 999143:
        raise ProbeError("Expected isolated Monad rehearsal chain 999143")
    config = json.loads((ROOT / "config/monad-mainnet.json").read_text())
    result = {"chainId": 999143, "dependencies": {}, "provenanceVerified": False}
    for name in ("usdc", "pythCore"):
        target = config[name]
        code = rpc(endpoint, "eth_getCode", [target, "latest"])
        if code in ("0x", "0x0"):
            raise ProbeError(f"Missing mainnet {name} code on the fork")
        result["dependencies"][name] = target
    if int(rpc(endpoint, "eth_call", [{"to": config["usdc"], "data": "0x313ce567"}, "latest"]), 16) != 6:
        raise ProbeError("Fork USDC must have six decimals")
    # Presence and decimals are necessary, but do not prove fork ancestry or signed-update compatibility.
    result["pending"] = ["verify parent 143 and fresh source block from Tenderly environment metadata",
                         "verify a new Hermes payload against this fork's actual Pyth router state"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("support", "project", "check-fork", "alerts"))
    parser.add_argument("--manifest", help="Actual deployment manifest; omit to prepare unbound event definitions")
    parser.add_argument("--market", action="append", default=[], help="Deployed clone, once per market")
    parser.add_argument("--network-id", help="Tenderly's verified alert target network ID")
    args = parser.parse_args()
    env = load_env()
    folder = ROOT / "reports/tenderly"
    folder.mkdir(parents=True, exist_ok=True)
    if args.command == "support":
        result = {"checkedAt": datetime.now(timezone.utc).isoformat(), "source": REGISTRY,
                  "network": monad_support(request_json(REGISTRY))}
        name = "network-support.json"
    elif args.command == "project":
        result, name = project_status(env), "project-status.json"
    elif args.command == "check-fork":
        result, name = check_fork(env), "fork-check.json"
    else:
        definitions = event_definitions()
        result = {"status": "definitions-only", "createdOnTenderly": False, "events": definitions}
        if args.manifest:
            manifest = json.loads((ROOT / args.manifest).read_text())
            result["payloads"] = alert_payloads(definitions, args.network_id, manifest["vault"], args.market,
                                                env.get("TENDERLY_DELIVERY_CHANNEL_ID"))
            result["status"] = "bound-plan-not-published"
        name = "alerts-plan.json"
    (folder / name).write_text(json.dumps(result, indent=2) + "\n")
    print(f"Saved reports/tenderly/{name}")
    if args.command == "support":
        print("Confirmed Monad mainnet 143: Virtual TestNets, monitoring, simulator and explorer")
    elif args.command == "project":
        print(json.dumps(result, indent=2))
    elif args.command == "alerts":
        print("Prepared four event categories. No alert has been created or notification sent.")
    else:
        print("Fork chain/dependency checks passed; provenance and new signed Pyth update still required.")


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
