#!/usr/bin/env python3
"""Run the pinned, read-only Monad fork suite and save redacted local output."""
import json
import subprocess
import urllib.parse

from monad_preflight import ROOT, ProbeError, load_env, rpc


def main():
    env = load_env()
    endpoint = env.get("ALCHEMY_MONAD_RPC")
    if not endpoint:
        raise SystemExit("Set ALCHEMY_MONAD_RPC in .env")
    report_file = ROOT / "reports/monad/preflight.json"
    if not report_file.exists():
        raise SystemExit("Run python3 scripts/monad_preflight.py first")
    report = json.loads(report_file.read_text())
    if report["chainId"] != 143 or report["forkBlock"] <= 0:
        raise SystemExit("Invalid Monad mainnet preflight")
    try:
        header = rpc(endpoint, "eth_getBlockByNumber", [hex(report["forkBlock"]), False])
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
    if header["hash"] != report["forkHash"]:
        raise SystemExit("Pinned block hash changed; rerun preflight before testing")
    if "updateFork" in report:
        update = report["updateFork"]
        try:
            header = rpc(endpoint, "eth_getBlockByNumber", [hex(update["block"]), False])
        except ProbeError as exc:
            raise SystemExit(str(exc)) from None
        if header["hash"] != update["hash"]:
            raise SystemExit("Signed-update block hash changed; rerun preflight before testing")
    governance = report.get("governanceFork", {})
    if "block" in governance:
        try:
            header = rpc(endpoint, "eth_getBlockByNumber", [hex(governance["block"]), False])
        except ProbeError as exc:
            raise SystemExit(str(exc)) from None
        if header["hash"] != governance["hash"]:
            raise SystemExit("Factory governance block hash changed; rerun preflight before testing")
    env.update(FOUNDRY_PROFILE="monad", MONAD_FORK_ENABLED="true", MONAD_FORK_BLOCK=str(report["forkBlock"]))
    result = subprocess.run(["forge", "test", "-vv"], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = result.stdout
    secrets = [endpoint, env.get("PYTH_API_KEY", "")]
    parsed = urllib.parse.urlsplit(endpoint)
    secrets += [v for _, v in urllib.parse.parse_qsl(parsed.query)]
    secrets += [part for part in parsed.path.split("/") if len(part) > 12]
    for secret in sorted(filter(None, secrets), key=len, reverse=True):
        output = output.replace(secret, "[REDACTED]")
    (ROOT / "reports/monad/fork.log").write_text(output)
    print(output, end="")
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
