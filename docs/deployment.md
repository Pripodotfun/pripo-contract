# Tenderly staging and mainnet rollout

## Staging decision — October 5

The shared staging environment is a **fresh Tenderly Virtual TestNet fork of Monad mainnet**, using mainnet USDC, mainnet Pyth and production state. Monad testnet is reserved for Friday's one-hour gas/timing pass and Mera P-256 verification if Mera is selected. Testnet faucets and mock-USDC staging are removed from this plan.

Tenderly's [live network registry](https://api.tenderly.co/api/v1/supported-networks) was checked on October 5: Monad, chain **143**, is a mainnet with `virtual_testnet`, `monitoring`, `simulator` and `explorer` all enabled. `make tenderly-support` refreshes and saves the evidence in `reports/tenderly/network-support.json`. Its [Monad support announcement](https://tenderly.co/blog/tenderly-supports-monad-from-day-one/) also explicitly covers Virtual TestNets.

The virtual chain ID is **999143**, keeping rehearsal signatures separate from production while retaining mainnet contract addresses. Saturday replays the same scripts and reviewed deployment sequence with production roles, chain ID, nonces and fresh signatures. It does not reuse signed rehearsal transactions.

**Current hosted status:** no Tenderly credentials are configured, so no hosted fork, fork Safes or live alerts have been created. The local deployment rehearsal below remains evidence for local execution only.

## Existing local rehearsal evidence

Deployment tooling is implemented. The October 5 rehearsal created **19 contracts** on a local Monad mainnet fork: 11 linked libraries, the vault implementation and initialized ERC-1967 proxy, market implementation, two adapters, backstop, sweeper and factory. No transaction was submitted to a public network.

The creation simulation estimated **44,622,346 gas**, including Foundry's default gas multiplier. This is a simulated transaction-limit budget, not a Monad-native execution measurement or a charged fee. Individual limits are retained in `reports/deployment/rehearsal.json`; actual submitted limits and charged gas/fees remain null. Foundry's generic `ETH` label refers to the target network's native currency in this output.

The lifecycle regression uses block **110131422** for creation and Governor setup, then block **110731422** for signed-price trading. Their real timestamps are **181,260 seconds** apart. Only the local protocol deployments persist across forks; USDC and Pyth use the real state at each block. It verifies delayed adapter activation, rejection before reserve funding, a 10,000-USDC reserve contribution, 500-USDC feed listing, 5,000-USDC market seed, market creation with a signed BTC update, open/close, withdrawal, fee sweeping and vault cash reconciliation. Test balances and roles are synthetic.

## Repeat the rehearsal

With the existing archive RPC, Pyth capture and dependencies:

```sh
make deployment-dry-run
```

The runner checks chain ID and pinned block hashes, runs `DeployPripo`, then the full lifecycle regression. It has no signing or broadcast option. Config, address/code-hash manifest, ordered Governor calldata, redacted logs and the result summary go in ignored `reports/deployment/`. Foundry also writes its unsigned transaction plan to ignored `broadcast/DeployPripo.s.sol/143/dry-run/`. The manifest records simulated addresses; it does not establish a live deployment. A failed rerun leaves the summary marked incomplete.

## Fresh fork and Safe setup

Supply `TENDERLY_ACCESS_KEY`, `TENDERLY_ACCOUNT_SLUG`, `TENDERLY_PROJECT_SLUG`, the Virtual TestNet Admin RPC as `TENDERLY_RPC`, and the existing on-call `TENDERLY_DELIVERY_CHANNEL_ID` in ignored `.env`. The mainnet RPC and Pyth key already exist. Never publish the Admin RPC; it can mutate the environment.

Create the environment on the day of testing with parent network **143**, virtual chain **999143**, and a newly observed mainnet block. Save the parent block number, hash, timestamp, environment ID and instance ID. Refork from mainnet before the final rehearsal; cloning Tuesday's already-mutated environment is not a fresh mainnet fork. Freeze state synchronization for deterministic fault/time scenarios and record any balance, block, time or storage changes separately from the production deployment manifest.

`python3 scripts/tenderly_stage.py check-fork` checks the virtual chain and dependency presence/USDC decimals. It deliberately does **not** certify ancestry or freshness: compare the source block in Tenderly's environment metadata with the mainnet RPC, then fetch a new Hermes payload and verify it against that fork's actual Pyth router state. Preserve the receipt and payload publish time. A cached observation or an old signed payload is not that test.

The configuration template uses:

- USDC: `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`.
- Upgraded Pyth Core: `0xB754BA51E3861Ac0Cb67f73CD046dE790A36508d`.
- Current oracle timing parameters: 3 seconds and 300 ms. These are protocol inputs, not a claim about Tenderly's block production.
- `slashToReserve=true`, retained from the existing rehearsal. Review this immutable policy in the production config.

`CreateRehearsalSafes` checks the canonical Safe 1.4.1 factory and singleton runtime hashes from [Safe's deployment registry](https://github.com/safe-global/safe-deployments/tree/main/src/assets/v1.4.1). It creates distinct Governor 3-of-5, Guardian 2-of-3, Council 3-of-5 and rehearsal Treasury 3-of-5 Safes, then writes their addresses into `DEPLOY_CONFIG`. Treasury's rehearsal threshold is a staging assumption; production uses the user's final Safe. The Council Safe is prepared for Resolver integration; the current vault has no Council field.

The rehearsal keys are intentionally public and deterministic. Both Safe scripts reject public chains. Production uses the independently created Safes with real signers provided by Friday. `rehearsalOnly` configs also reject a change to a public chain ID. Default to temporary rehearsal signers until specific fork owners are supplied.

```sh
# Public sender address; use a dedicated rehearsal sender funded only on the fork.
export DEPLOYER=0xYOUR_REHEARSAL_SENDER_ADDRESS
# Set DEPLOY_CONFIG/DEPLOY_OUTPUT as in .env.example and create reports/deployment first.
forge script script/RehearsalSafes.s.sol:CreateRehearsalSafes --rpc-url tenderly --sender "$DEPLOYER"
```

These commands simulate unless `--broadcast` is supplied. Submit the reviewed Safe creation plan to the isolated Tenderly fork before simulating dependent protocol deployment. Fund fork balances against the real USDC token using Tenderly's supported administrative methods; contributions to the vault still use normal USDC approvals/transfers. Do not install replacement USDC or Pyth bytecode. For fork submission use the dedicated rehearsal sender or the fork's supported unsigned-transaction path; do not reuse production signatures.

## Deployment stages

The following commands simulate only. Set the shell's `DEPLOYER` to the same public address as `.env` so Foundry's library transaction sender matches the core contract sender:

```sh
export DEPLOYER=0xYOUR_PUBLIC_DEPLOYER_ADDRESS
forge script script/DeployPripo.s.sol:DeployPripo --rpc-url tenderly --sender "$DEPLOYER"
```

Foundry links the library dependency graph and records the creation sequence. Review the config, manifest, transaction plan and individual gas limits before live execution. Broadcasting requires a separately authorized invocation with `--broadcast` and the selected wallet, as described in [Foundry's deployment documentation](https://getfoundry.sh/forge/deploying). Preserve the transaction plan and receipts. If interrupted, reconcile receipts and resume the existing plan with Foundry's `--resume`; rerunning creation from scratch would deploy another set of core contracts.

After successful creation, the Governor executes these zero-value calls in order:

1. Vault `setBackstopController(backstop)`.
2. Vault `setRegistrar(factory, true)`.
3. Factory `scheduleAdapter(pythAdapter)`.

The manifest's `governanceTargets`, `governanceValues` and `governanceCalldata` arrays contain the exact calls for a multisig. For the temporary fork Governor, execute the same calls through the actual Safe threshold:

```sh
forge script script/RehearsalSafes.s.sol:ConfigureRehearsalSafes --rpc-url tenderly --sender "$DEPLOYER"
```

`ConfigureRehearsalSafes` signs the manifest calls with three temporary owners and invokes Safe `execTransaction`; it does not impersonate the Governor. It rejects a partially started setup so the existing Safe nonce and completed calls must be reconciled before continuing. Production Safes sign the same reviewed calldata with their actual owners.

`ConfigurePripo` remains available for EOA configurations and has no linked library deployments. It validates recorded runtimes, proxy implementation, dependency bindings and roles. It skips completed setup calls and preserves an existing adapter deadline. A conflicting backstop rejects before any setup transaction is recorded. The raw multisig bundle is for initial setup: after partial execution, omit completed calls, especially the one-time backstop binding and already-pending adapter schedule.

After the full one-day delay, anyone can simulate and subsequently execute activation:

```sh
forge script script/DeployPripo.s.sol:ConfigurePripo --sig 'activate()' --rpc-url tenderly
```

Fund the reserve using USDC approval followed by `fundProtocolReserve(10000000000)` before admitting the first market. Funding is a separate, irrevocable capital contribution; deployment does not transfer tokens. Feed listing and external market creation require another 500 USDC and 5,000 USDC respectively. Refresh oracle updates at execution time. Confirm the vault roles, factory registrar, backstop binding, adapter approval and reserve ledger from live state before opening a market.

## Rehearsal matrix and debugger evidence

| Scenario | Required result |
| --- | --- |
| Deployment and role wiring | Safe owners/thresholds and proxy roles verified; a below-threshold Governor transaction fails; actual signed Safe execution binds factory and backstop and schedules Pyth |
| Full ADL | Full book, 64 matches per call, continuations and book mutation; reservations isolated; funding frozen; totals/cash reconciled |
| Forced settlement | Fresh whole-book insufficiency proof, correct capital waterfall, terminal-only deficit and user withdrawal checks |
| Resolver | Before/at/after dispute deadline; matched bonds, disputed/undisputed outcomes, Council-only resolution and settlement; **pending implementation** |
| Stale wind-down | Before/at/after the stale threshold and Resolver authorization; **pending implementation** |
| Long funding gap | Advance blocks; capacity clamp, receiver-first settlement, no unbacked credits, no catch-up on resume |
| Degraded | Check stale age at 100 and 101 blocks (the rule is strictly greater than 100), zero funding, blocked opens, working closes and recovery on fresh data |

Use Tenderly's [Admin RPC](https://docs.tenderly.co/virtual-environments/admin-rpc) to advance **blocks and time independently**. Funding and Degraded tests assert the actual block delta; timestamp-based adapter governance asserts elapsed seconds. Resolver tests follow its specified block deadlines. Assert the Degraded boundary against the market's cached index block. For interactions that read Pyth again, control elapsed seconds too: the adapter derives `updatedBlock` from timestamp age, so an unchanged virtual clock can make a cached provider price look fresh despite a block jump. After a forward time jump, restore the baseline snapshot or refork before live-Pyth tests; current real-world payloads cannot be made fresh by reusing them against a future virtual clock.

Retain a transaction hash, pre/post state, assertions and debugger URL for every failure, including expected authorization/deadline failures. Distinguish test-only legacy-debt injection used to stress ADL/settlement from normal production funding, which must remain cash-backed. Test-only shock helpers and their state mutations are excluded from the production replay. A passing recovery test does not establish that the injected debt is reachable under current funding caps.

## Alerts

`make tenderly-alerts` builds the four definitions from the committed runtime ABIs. `BadDebt`, `StatusChanged` and `ForcedSettlement` are emitted at each **market clone**; `DeficitChanged` is emitted at the **vault proxy**. Binding targets to implementation or library addresses would miss those events. Monitor every transition/deficit change, including recovery to zero.

After deployment, build a concrete plan with `--manifest`, one `--market` argument per clone, a verified Tenderly alert `--network-id`, and the destination ID in `.env`:

```sh
python3 scripts/tenderly_stage.py alerts --manifest reports/deployment/tenderly-manifest.json --network-id VERIFIED_TENDERLY_TARGET_ID --market 0xFIRST_CLONE --market 0xSECOND_CLONE --market 0xTHIRD_CLONE
```

Four categories yield ten emitter-specific rules for three markets. The saved `alerts-plan.json` contains the event signatures, topics and documented Tenderly API payloads. It is a **plan**, not proof of remote creation. Add the actual targets to the Tenderly project, create the rules using the [Alerts API](https://docs.tenderly.co/monitoring/alerts/api), then record alert IDs and delivery evidence for each category. Mainnet monitoring support does not alone prove that a particular Virtual TestNet is accepted as an alert target; confirm that capability and actual delivery in the project. Do not substitute virtual chain ID 999143 for a Tenderly-specific network identifier without verification.

On Saturday, regenerate against chain 143 and actual production addresses, verify enabled rules and destinations, and record a delivery test. Every newly created permissionless market must be enrolled; the three launch clones are not permanent coverage of the entire factory. Keep fork and production rule IDs separate. Access, destination selection and deployment addresses currently block remote creation; no alert is described as live until created and verified.

## Week and release gate

| Day | Deliverable |
| --- | --- |
| Tue Oct 6 | Fresh Monad-mainnet Virtual TestNet; fork Safes; full deployment/governance and implemented recovery rehearsals; alerts bound and delivery tested where supported |
| Wed–Thu Oct 7–8 | Resolver/dispute/stale-wind-down implementation and regressions; fresh mainnet fork and full rerun |
| Thu night | Resolver green or select the fork-demo submission; mainnet then moves to judging week |
| Fri Oct 9 | Security checks and one-hour real Monad testnet measurement pass; real mainnet Safes/signers and USDC/MON capital ready |
| Sat Oct 10 | Replay reviewed scripts with production configuration if every gate is green; alerts live; reserve and bonds funded; three markets created; submit that night |

**Adapter-delay dependency:** the factory has an unmodified one-day approval delay. Saturday creation of Pyth markets needs the factory deployed and the adapter scheduled on Friday. If all infrastructure is first deployed Saturday, Pyth markets wait until Sunday. Oracle-less markets do not require Pyth approval. The Friday-infrastructure versus Saturday-only choice is pending; no mainnet approval delay is bypassed for the schedule.

Friday's four planned stress measurements are the first 64-match ADL call, bounded fallback completion, 128-position forced settlement, and a full payer-book funding checkpoint after a long gap. Also retain deployment/provider update receipts. Report RPC estimate, submitted gas limit, receipt gas used, effective gas price, transferred native value and isolated sender balance delta; derive the actual charged fee separately. Fork simulation numbers are not charged Monad fees. Check chain 10143 and real deployment dependencies during this measurement pass. Provision the required testnet MON/token balances in advance through the supplied access; no faucet or mock-USDC setup is part of staging.

If Mera is selected, include real Monad testnet P-256 verification and an end-to-end passkey transaction in the same hour. A Tenderly result cannot satisfy that gate. Otherwise record the path as not selected.

By Friday the user supplies mainnet Safes/signers, **10,000 USDC reserve**, market/listing bonds and MON for gas. Three distinct Pyth markets additionally need **16,500 USDC** in seed/listing bonds; three oracle-less markets require **6,000 USDC** seed bonds. Trading collateral is separate. Safes, fee destinations and all policy inputs are reviewed in the production config. The mainnet RPC and Pyth key are already available; equity entitlements and feed selection remain market-specific gates.

Markets are immutable clones. The Thursday fallback is a fork demo, not a resolver-less mainnet launch. Preserve the compiler/build settings, commit, linked-library addresses, constructor arguments, role manifests, simulation evidence and actual receipts for the final replay and explorer verification.
