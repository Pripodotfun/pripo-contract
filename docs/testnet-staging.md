# Monad testnet staging

## October 6 decision

Use public Monad testnet, chain **10143**, for the shared rehearsal and submission demo. Tenderly access and hosted alerts are deferred until access is available after submission. The shared production deployment code remains `PripoDeployment`; `DeployTestnet` adds signing through the configured testnet key and rejects every other chain before reading that key. A `testnetOnly` config cannot be retargeted to mainnet.

**October 9 update:** Tenderly access has now been granted. Resume the [fresh mainnet-fork rehearsal](deployment.md) after configuring its account/project credentials. This runbook remains the reference for the existing public demo and real Monad execution/fee measurements. Hosted deployment and alerts are still unverified; access alone is not a completed rehearsal.

### Mock collateral workflow

The active demo uses **Pripo Mock USDC (`mUSDC`)**, a six-decimal token deployed only on chain 10143. Its constructor minted 100,000 tokens to the deployer; anyone can call `faucet()` to mint another 10,000 to themselves. This is freely minted demo collateral, not Circle-issued or dollar-backed USDC.

The existing vault cannot change its collateral token through an administrative setter. `DeployMockTestnet` therefore verifies the native deployment, reuses its vault/market implementations, adapters and linked libraries, and creates five contracts: mock token, initialized vault proxy, backstop, sweeper and factory. It performs the same three governance calls and contributes **10,000 mUSDC** through a normal token approval and `fundProtocolReserve`. The reserve floor remains 10,000 tokens, with 90,000 left for demo bonds and trading. The new factory starts its own full 24-hour Pyth approval delay.

```sh
python3 scripts/mock_testnet.py deploy             # simulate all ten transactions
python3 scripts/mock_testnet.py deploy --broadcast # five creations, three governance calls, approve/fund
python3 scripts/mock_testnet.py deploy --verify-only
python3 scripts/mock_testnet.py status
# After the new factory's approval timestamp:
python3 scripts/mock_testnet.py activate --broadcast
```

Mock manifests, logs and receipt journals use `reports/deployment/mock-testnet/`; native deployment records remain in `reports/deployment/`. An existing mock journal/manifest blocks accidental redeployment. Verification checks exact call targets and amounts, all new/reused runtime hashes, real receipts, historical fee balances and the initial 10,000-token reserve backing. An interrupted broadcast must be reconciled with its saved Foundry transactions before continuing.

### First demo market

`CreateDemoMarket` creates `PRIPO:DEMO` through the active mock factory: oracle-less, initial price **100 mUSDC**, virtual quote depth **200,000 mUSDC**, and **2,000 mUSDC** transferred to market insurance. Depth is virtual pricing capacity; the seed is actual mock-token custody. The fixed factory caps give **2× maximum leverage** and an initial **20,000 mUSDC OI cap**. The script rejects other chains, non-mock manifests and an existing demo symbol. No Pyth activation is needed for the canonical NullAdapter.

```sh
python3 scripts/create_demo_market.py               # simulate approval and creation
python3 scripts/create_demo_market.py --broadcast   # submit those two transactions
python3 scripts/create_demo_market.py --verify-only # receipts and creation-block state, no signing
```

The runner validates exact calldata before submission and retains `market.json`, `market-receipts.json` and `market-broadcast.json` beside the mock manifest. It verifies the factory event, deterministic clone implementation, complete launch configuration, virtual reserves, zero initial positions/OI, seed custody and insurance, exhausted approval, unchanged protocol reserve and opens gate. Gas fees are reconciled against historical sender balances. A saved market journal blocks another broadcast; reconcile interrupted transactions before any retry.

### Margin-entry implementation upgrade

`scripts/margin_upgrade.py` upgrades the existing mock factory's implementation
for **future markets**. It deploys the new Market and its fixed linked modules,
then schedules the factory's on-chain **24-hour implementation delay**. Existing
clones and positions keep their implementation. The vault, collateral and factory
addresses stay the same.

```sh
python3 scripts/margin_upgrade.py rehearse             # pinned testnet fork; no broadcast
python3 scripts/margin_upgrade.py deploy               # exact deployment simulation
python3 scripts/margin_upgrade.py deploy --broadcast
python3 scripts/margin_upgrade.py schedule --broadcast
python3 scripts/margin_upgrade.py status               # UTC activation deadline
# After the recorded deadline:
python3 scripts/margin_upgrade.py activate --broadcast
python3 scripts/margin_upgrade.py create --broadcast
```

The new oracle-less market is `PRIPO:DEMO-V2`, seeded with **2,000 mUSDC**,
initial price **100 mUSDC** and virtual depth **200,000 mUSDC**. Its `marginEntryVersion()`
returns 1, enabling the web app's margin/leverage form automatically. Creation
does not deposit trading collateral or open a public-chain position.

Every write stage simulates first, validates its exact sender/targets/calldata,
checks the gas balance and creates an incomplete journal before broadcasting.
`reports/deployment/margin-upgrade/` contains the pinned rehearsal, manifests,
redacted logs, broadcast plans and receipt/fee verification. The runner requires
committed deployment sources, and deployment requires a matching rehearsal source
digest. A stage journal prevents duplicate submission; use `<stage> --verify-only`
to reconcile a completed/interrupted stage without signing. Do not delete journals
or re-run an incomplete broadcast without checking its saved transaction hashes.

### First demo position

`OpenDemoPosition` deposits **100 mUSDC** from the configured deployer and opens **one long base unit** on `PRIPO:DEMO`, with an absolute maximum average fill of **101 mUSDC**. The market computes required margin and fees; the unused deposit stays in the trader's free balance. The script checks the quote against both the price limit and the deposit budget before the first broadcast call, and requires that the trader has no existing position.

```sh
python3 scripts/open_demo_position.py               # quote and simulate three calls
python3 scripts/open_demo_position.py --broadcast   # exact approval, deposit, open
python3 scripts/open_demo_position.py --verify-only # recheck receipts at the opening block
```

The runner rejects different trade directions, sizes, limits, deposit amounts or targets. It records `open-position-receipts.json`, `open-position-broadcast.json` and `position.json` under the mock deployment folder. Receipt verification checks `PositionOpened`, on-chain size/entry/margin, locked and free balances, fee allocations, token custody, reserve preservation, exhausted approval and position health at the opening block. Existing journals block duplicate submission. If only approval/deposit succeeds, reconcile the saved transactions before retrying; the deposit remains in the vault's free balance.

The [first long](https://testnet.monadvision.com/tx/0xce77a3a0e45d188b4833a6257e55dbbee1b8d2d573f4084b38fde682cd12f01a) opened at block **68788491**, from script commit **`f1b962e`**, for deployer `0x3b2F1773a1B279A1b0b13aD425019C91433693c3`. Size is **1 base unit**, entry **100.050025012506253127 mUSDC**, locked margin **50.025012506253126564 mUSDC**, and opening fee **0.080040020010005003 mUSDC**. Free collateral is **49.894947473736868433 mUSDC**. The opening-block health check reports non-liquidatable; the position remains open in this stage.

Vault custody is now **12,100 mUSDC**, reserve remains **10,000 mUSDC**, and the wallet holds **87,900 mUSDC**. Insurance increased to **2,000.024012006003001500 mUSDC** from its fee share. All three receipts succeeded. Simulated gas limits totaled **1,093,300**, submitted/charged gas **1,170,197**, and fees **0.120530291001170197 testnet MON**, exactly reconciled to the historical wallet balance decrease. `positions` and `stages.openDemoPosition` in the active deployment record retain the opening evidence.

### Active mock deployment — October 6

All ten transactions succeeded from build commit **`c8e135c`**. At block **68711245**, the new vault holds **10,000 mUSDC**, `protocolReserve` is **10,000e18**, and the deployer retains **90,000 mUSDC**. The [active deployment record](../deployments/monad-testnet.json) contains the new addresses, reused code hashes, exact receipt evidence and fees. Demo clients should use this record.

| Contract | Active demo address |
| --- | --- |
| Mock USDC | [0xd0f68CF8Fe7725A34eE8312515FC27aD955D8fbF](https://testnet.monadvision.com/address/0xd0f68CF8Fe7725A34eE8312515FC27aD955D8fbF) |
| Vault proxy | [0x1980B3a41393f610a8BE552C71BAE3F42AAB6735](https://testnet.monadvision.com/address/0x1980B3a41393f610a8BE552C71BAE3F42AAB6735) |
| Factory | [0x133A614CBE2CBA1789E67E0898C0F5c56Eb7BBf0](https://testnet.monadvision.com/address/0x133A614CBE2CBA1789E67E0898C0F5c56Eb7BBf0) |
| PRIPO:DEMO market | [0xeA326A40694dA4D7C5c64719B48Ba561EcA8C0Eb](https://testnet.monadvision.com/address/0xeA326A40694dA4D7C5c64719B48Ba561EcA8C0Eb) |

Simulation estimated **6,612,590** gas limits. Mined transactions submitted and were charged **7,278,504** gas, costing **0.749685912007278504 testnet MON**, exactly matching the sender's historical balance decrease. The new factory's Pyth approval is activatable **October 7 at 14:40:01 UTC / 15:40:01 WAT**. Its reserve is funded, so oracle-less market admission has no collateral-supply blocker. No market creation is claimed by this deployment stage. Resolver and stale wind-down remain unfinished.

The subsequent market creation stage from script commit **`d0f7b1e`** succeeded at block **68730216**. [`PRIPO:DEMO` creation transaction](https://testnet.monadvision.com/tx/0xe0b520fcf7f9ad825203a5c6240ca68bb2ddf5dc1b7b271094f1cb44b377794e) emitted the expected factory event; registry, clone implementation and complete launch configuration match. The market is **Active**, its opens gate passes, initial price is **100 mUSDC**, insurance is **2,000 mUSDC**, leverage is capped at **2×**, and initial OI capacity is **20,000 mUSDC**. It has no positions at this snapshot. Vault custody is now **12,000 mUSDC**: 10,000 reserve plus 2,000 market insurance. The deployer retains **88,000 mUSDC**.

Approval plus creation simulated **1,201,357** gas limits; actual submitted limits and receipt gas totaled **1,358,226**, costing **0.139897278001358226 testnet MON**. Historical sender balances reconcile exactly. The active deployment record includes the market under `markets`, both receipts under `stages.createDemoMarket`, and the creation-block state under `onchainStatus`.

## Native dependency reference

| Dependency | Testnet address | Source |
| --- | --- | --- |
| Circle test USDC, six decimals | `0x534b2f3A21130d7a60830c2Df862319e593943A3` | [Circle](https://developers.circle.com/stablecoins/usdc-contract-addresses) |
| Upgraded Pyth Core | `0xFC6bd9F9f0c6481c6Af3A7Eb46b296A5B85ed379` | [Pyth](https://docs.pyth.network/price-feeds/core/upgrade/contracts) |

Both addresses have code through the supplied testnet RPC. A fresh signed BTC payload was accepted by Pyth through `eth_call` at block **68675000**, with price age one second, confidence two basis points and zero provider update fee. The provider-only RPC gas estimate was **175,850**. This check does not submit a transaction or pay gas, and a fresh payload is required again for each live price-dependent operation.

## Original native-USDC deployment — October 6

The original core stack was deployed from contract build commit **`0ef1922`**. All 19 creations and three Governor transactions succeeded, all runtime hashes match, and the factory/backstop bindings and final testnet roles pass live reads. The archived [native deployment record](../deployments/monad-testnet-native.json) contains addresses, code hashes, transaction hashes, exact fees and status at block **68681084**. Its unfunded native-USDC vault is not the active mock demo vault.

| Contract | Address |
| --- | --- |
| Vault proxy | [0x2AFfCA5C5868eD8D6C6E9B5a430da5f8430DF3bF](https://testnet.monadvision.com/address/0x2AFfCA5C5868eD8D6C6E9B5a430da5f8430DF3bF) |
| Factory | [0xcF6D11AFB01C045085D615F27A90835e2eF7faE9](https://testnet.monadvision.com/address/0xcF6D11AFB01C045085D615F27A90835e2eF7faE9) |
| Market implementation | `0x79Bea8B8fb87e2518e61f1D78a5c0f35Dd2013E4` |
| Pyth adapter | `0xA8e7c178fb8d1672436A35D0BaC7e5243b7FB771` |

The testnet Governor, Guardian and Treasury are `0x3b2f1773a1b279a1b0b13ad425019c91433693c3`. Pyth approval becomes activatable at **October 7, 12:05:24 UTC / 13:05:24 WAT**. At the recorded snapshot the reserve and deployer's native test USDC balance are both zero, so no market has been created. Resolver and stale wind-down remain unfinished; this deployment is not production-ready.

| Stage | Simulated gas limits | Submitted limits / receipt gas | Charged testnet MON |
| --- | ---: | ---: | ---: |
| 19 creations | 43,381,476 | 43,580,031 | 4.488743193 |
| 3 Governor calls | 370,041 | 370,041 | 0.0420736617 |
| Total fees | | | **4.5308168547** |

The submitted limits come from mined RPC transactions. They differ from the unsigned Foundry plan. Receipt gas equals the actual submitted limits for these transactions; receipt-derived fees exactly equal sender balance decreases at historical block boundaries. These deployment measurements do not replace the four recovery/funding stress measurements.

## Commands and credentials

Use ignored `.env` for `ALCHEMY_MONAD_TESTNET_RPC` (or `MONAD_TESTNET_RPC`), `PYTH_API_KEY` and `FUNDED_DEPLOYER_PRIVATE_KEY`. Never put the key in command-line arguments or commit it. The runner derives the public address with the key passed to OpenSSL over stdin. If `DEPLOYER` is supplied, it must match the key. Optional `TESTNET_GOVERNOR`, `TESTNET_GUARDIAN` and `TESTNET_TREASURY` override the staging roles; otherwise all three use the testnet deployer. These EOA defaults do not establish production Safe readiness or threshold testing.

```sh
make testnet-preflight
make testnet-dry-run
python3 scripts/deploy_testnet.py deploy
python3 scripts/deploy_testnet.py deploy --broadcast
python3 scripts/deploy_testnet.py deploy --verify-only
python3 scripts/deploy_testnet.py configure --broadcast
python3 scripts/deploy_testnet.py status
# Run only after the on-chain approval timestamp:
python3 scripts/deploy_testnet.py activate --broadcast
```

The first three commands are simulations/read-only. `--broadcast` executes only on chain 10143, after a successful simulation and a conservative MON balance check. Signing uses Foundry's in-process wallet; logs are redacted before printing/saving. The deploy runner refuses to create a second deployment when a live manifest or deployment journal exists. If a broadcast is interrupted, reconcile recorded transaction hashes and Foundry's resume data before any retry. Never delete a deployment record to bypass this guard.

Reports in ignored `reports/deployment/` separate simulated manifests from `testnet-manifest.json` and verified live receipt journals. All 19 creation transactions must match the manifest and deployed runtime hashes. Eight direct creations supply a receipt `contractAddress`; eleven library creations use the canonical CREATE2 proxy and are verified by deriving the address from its on-chain salt/initcode, then checking the runtime hash. `--verify-only` rechecks an existing journal without signing or resubmitting. Each receipt report records the submitted gas limit, receipt gas used, effective gas price, receipt-derived fee, native value and sender balance delta. A failed balance reconciliation requires investigating other wallet activity or network fee semantics; do not equate it with a measured charged fee.

The October 6 unsigned creation simulation passed at testnet block **68674980**, using **43,381,476** simulated transaction gas limits. At the observed 102-gwei RPC gas price that is about **4.425 MON**; Foundry's displayed 203-gwei estimate was about **8.806 MON**. These are planning estimates. The wallet held 40 testnet MON and zero test USDC at that observation. Live fees must come from receipts and balance reconciliation.

## Capital and timing

Using Circle test USDC, the unchanged reserve floor needs **10,000 test USDC**. One oracle-less market adds a 2,000-token seed; one Pyth market adds a 500-token feed listing and 5,000-token seed. Three oracle-less launch demos therefore need 16,000 test USDC before trading collateral, or 26,500 for three distinct Pyth feeds. Native test USDC uses the same transfer/decimal integration as the production asset. A separate demo faucet-token deployment, if selected, must be labelled explicitly and cannot be presented as native-USDC integration evidence.

The factory's Pyth adapter approval requires **24 real hours** after `scheduleAdapter`. Oracle-less market creation has no adapter delay but still requires the reserve. Public testnet cannot fast-forward that deadline. Production timing, capital, final Safes and the Resolver release gate are independent of testnet completion.

## Coverage split

- Public testnet: deploy, role wiring, actual oracle updates, funding/market/trading flows, revert receipts and traces, gas limits and charged fees; Mera P-256 and end-to-end passkey verification if selected.
- Local mainnet/testnet forks: accelerated dispute-window boundaries, stale wind-down, Degraded at 100/101 blocks, long funding gaps, full-book ADL and forced-settlement stress. Recovery fixtures that inject legacy debt stay explicitly labelled.
- Tenderly (access granted October 9; workspace credentials pending): hosted fresh-fork replay, Safe threshold rehearsal, debugger links and remote alert delivery where supported. Prepared alert definitions are not live monitoring.

Resolver and stale wind-down remain implementation milestones. The original Wednesday–Thursday targets did not establish completion. Retain the four real-Monad stress measurements and security checks; use a verified demo and postpone mainnet if the Resolver gate is not green. Do not launch immutable production markets while their settlement path is unfinished.
