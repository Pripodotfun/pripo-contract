.PHONY: deps build test ci fmt abi

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
