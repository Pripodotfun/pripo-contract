# Monad testnet staging

## October 6 decision

Use public Monad testnet, chain **10143**, for the shared rehearsal and submission demo. Tenderly access and hosted alerts are deferred until access is available after submission. The shared production deployment code remains `PripoDeployment`; `DeployTestnet` adds signing through the configured testnet key and rejects every other chain before reading that key. A `testnetOnly` config cannot be retargeted to mainnet.

| Dependency | Testnet address | Source |
| --- | --- | --- |
| Circle test USDC, six decimals | `0x534b2f3A21130d7a60830c2Df862319e593943A3` | [Circle](https://developers.circle.com/stablecoins/usdc-contract-addresses) |
| Upgraded Pyth Core | `0xFC6bd9F9f0c6481c6Af3A7Eb46b296A5B85ed379` | [Pyth](https://docs.pyth.network/price-feeds/core/upgrade/contracts) |

Both addresses have code through the supplied testnet RPC. A fresh signed BTC payload was accepted by Pyth through `eth_call` at block **68675000**, with price age one second, confidence two basis points and zero provider update fee. The provider-only RPC gas estimate was **175,850**. This check does not submit a transaction or pay gas, and a fresh payload is required again for each live price-dependent operation.

## Commands and credentials

Use ignored `.env` for `ALCHEMY_MONAD_TESTNET_RPC` (or `MONAD_TESTNET_RPC`), `PYTH_API_KEY` and `FUNDED_DEPLOYER_PRIVATE_KEY`. Never put the key in command-line arguments or commit it. The runner derives the public address with the key passed to OpenSSL over stdin. If `DEPLOYER` is supplied, it must match the key. Optional `TESTNET_GOVERNOR`, `TESTNET_GUARDIAN` and `TESTNET_TREASURY` override the staging roles; otherwise all three use the testnet deployer. These EOA defaults do not establish production Safe readiness or threshold testing.

```sh
make testnet-preflight
make testnet-dry-run
python3 scripts/deploy_testnet.py deploy
python3 scripts/deploy_testnet.py deploy --broadcast
python3 scripts/deploy_testnet.py configure --broadcast
# Run only after the on-chain approval timestamp:
python3 scripts/deploy_testnet.py activate --broadcast
```

The first three commands are simulations/read-only. `--broadcast` executes only on chain 10143, after a successful simulation and a conservative MON balance check. Signing uses Foundry's in-process wallet; logs are redacted before printing/saving. The deploy runner refuses to create a second deployment when a live manifest or deployment journal exists. If a broadcast is interrupted, reconcile recorded transaction hashes and Foundry's resume data before any retry. Never delete a deployment record to bypass this guard.

Reports in ignored `reports/deployment/` separate simulated manifests from `testnet-manifest.json` and verified live receipt journals. All 19 creation receipts must match the manifest and deployed runtime hashes. Each receipt report records the submitted gas limit, receipt gas used, effective gas price, receipt-derived fee, native value and sender balance delta. A failed balance reconciliation requires investigating other wallet activity or network fee semantics; do not equate it with a measured charged fee.

The October 6 unsigned creation simulation passed at testnet block **68674980**, using **43,381,476** simulated transaction gas limits. At the observed 102-gwei RPC gas price that is about **4.425 MON**; Foundry's displayed 203-gwei estimate was about **8.806 MON**. These are planning estimates. The wallet held 40 testnet MON and zero test USDC at that observation. Live fees must come from receipts and balance reconciliation.

## Capital and timing

Using Circle test USDC, the unchanged reserve floor needs **10,000 test USDC**. One oracle-less market adds a 2,000-token seed; one Pyth market adds a 500-token feed listing and 5,000-token seed. Three oracle-less launch demos therefore need 16,000 test USDC before trading collateral, or 26,500 for three distinct Pyth feeds. Native test USDC uses the same transfer/decimal integration as the production asset. A separate demo faucet-token deployment, if selected, must be labelled explicitly and cannot be presented as native-USDC integration evidence.

The factory's Pyth adapter approval requires **24 real hours** after `scheduleAdapter`. Oracle-less market creation has no adapter delay but still requires the reserve. Public testnet cannot fast-forward that deadline. Production timing, capital, final Safes and the Resolver release gate are independent of testnet completion.

## Coverage split

- Public testnet: deploy, role wiring, actual oracle updates, funding/market/trading flows, revert receipts and traces, gas limits and charged fees; Mera P-256 and end-to-end passkey verification if selected.
- Local mainnet/testnet forks: accelerated dispute-window boundaries, stale wind-down, Degraded at 100/101 blocks, long funding gaps, full-book ADL and forced-settlement stress. Recovery fixtures that inject legacy debt stay explicitly labelled.
- After Tenderly access: hosted fresh-fork replay, Safe threshold rehearsal, debugger links and remote alert delivery. Prepared alert definitions are not live monitoring.

Resolver and stale wind-down remain implementation milestones. Wednesday–Thursday targets those paths; Friday retains the four stress measurements and security checks. If Resolver is not green Thursday night, submit the testnet demo and move mainnet to judging week. Do not launch immutable production markets while their settlement path is unfinished.
