#!/usr/bin/env python3
"""Export canonical JSON ABIs; the standalone pripo-sdk repo owns TypeScript generation."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = {
    "Market": "marketAbi",
    "IMarketCore": "marketCoreAbi",
    "IMarket": "plannedMarketAbi",
    "MarketFactory": "marketFactoryAbi",
    "IMarketFactory": "marketFactoryInterfaceAbi",
    "FeeSweeper": "feeSweeperAbi",
    "PythAdapter": "pythAdapterAbi",
    "NullAdapter": "nullAdapterAbi",
    "MarginVault": "marginVaultAbi",
    "IMarginVault": "marginVaultInterfaceAbi",
    "InsuranceBackstop": "insuranceBackstopAbi",
    "IInsuranceBackstop": "insuranceBackstopInterfaceAbi",
    "Resolver": "resolverAbi",
    "IResolver": "resolverInterfaceAbi",
    "IPriceSource": "priceSourceAbi",
    "IPripoErrors": "pripoErrorsAbi",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if committed exports differ from the build artifacts")
    args = parser.parse_args()
    outputs = {}
    for contract in CONTRACTS:
        artifact = ROOT / "out" / f"{contract}.sol" / f"{contract}.json"
        if not artifact.is_file():
            raise SystemExit(f"Missing {artifact.relative_to(ROOT)}; run forge build first.")
        abi = json.loads(artifact.read_text())["abi"]
        text = json.dumps(abi, indent=2, ensure_ascii=False)
        outputs[ROOT / "abi" / f"{contract}.json"] = text + "\n"
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"ABI export is stale: {path.relative_to(ROOT)}; run make abi.")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    print(f"{'Checked' if args.check else 'Exported'} {len(CONTRACTS)} canonical JSON ABIs.")


if __name__ == "__main__":
    main()
