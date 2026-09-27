.PHONY: deps build test ci fmt abi analyze

deps:
	forge install --no-git --shallow foundry-rs/forge-std@v1.11.0 OpenZeppelin/openzeppelin-contracts@v5.4.0

build:
	forge build
	forge lint src --deny warnings

test:
	forge test

ci:
	forge fmt --check
	forge lint src --deny warnings
	FOUNDRY_PROFILE=ci forge test
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
