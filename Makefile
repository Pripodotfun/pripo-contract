.PHONY: deps build test ci fmt abi analyze monad-preflight monad-fork monad-estimate-pyth deployment-dry-run tenderly-support tenderly-alerts testnet-preflight testnet-dry-run

deps:
	forge install --no-git --shallow foundry-rs/forge-std@v1.11.0 OpenZeppelin/openzeppelin-contracts@v5.4.0

build:
	forge build --sizes
	forge lint src --deny warnings

test:
	forge test

ci:
	forge fmt --check
	forge build --sizes
	forge lint src --deny warnings
	FOUNDRY_PROFILE=ci forge test
	python3 -m unittest discover -s test/scripts
	python3 scripts/export_abis.py --check

fmt:
	forge fmt

abi:
	forge build
	python3 scripts/export_abis.py

analyze:
	mkdir -p reports
	slither . --skip-clean --filter-paths 'lib/|test/' --exclude-dependencies --fail-medium
	FOUNDRY_EVM_VERSION=cancun aderyn . --src src --path-excludes lib/,test/ --skip-update-check --output reports/aderyn.md

monad-preflight:
	python3 scripts/monad_preflight.py

monad-fork:
	python3 scripts/run_monad_fork.py

monad-estimate-pyth:
	python3 scripts/monad_estimate_pyth.py

deployment-dry-run:
	python3 scripts/dry_run_deployment.py

tenderly-support:
	python3 scripts/tenderly_stage.py support

tenderly-alerts:
	python3 scripts/tenderly_stage.py alerts

testnet-preflight:
	python3 scripts/testnet_stage.py preflight

testnet-dry-run:
	python3 scripts/testnet_stage.py dry-run
