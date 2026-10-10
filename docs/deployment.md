# Deployment and staging

## Current status — October 10

The active Tenderly deployment uses **single-account governance**, as requested. `PRIPO:DEMO` is created and its opening gate passes. The vault holds **12,000 fork-USDC**: a 10,000-USDC protocol reserve and 2,000-USDC market insurance. The market starts at 100, with virtual depth 200,000 and a 2× leverage cap, and uses the oracle-free curve. [Current Tenderly addresses and receipts](../deployments/tenderly-demo.json) include the deployed margin-and-leverage entry implementation.

The demo Governor, Guardian and Treasury are the rehearsal account `0x00000000000000000000000000000000000A11cE`. Four separate custody/factory contracts reuse the already verified implementations and libraries. Deployment, direct governance, reserve funding and market creation completed in ten successful transactions. No Safe execution or typed signatures are used by this workflow.

The RPC still reports `999143` while EVM `CHAINID` reads `1`. The dedicated demo runner verifies the authenticated environment/instance, disabled state sync and both observed chain IDs; it records this limitation explicitly. The [earlier Safe deployment](../deployments/tenderly-rehearsal.json) and [signature-domain reproduction](tenderly-chain-domain-issue.md) remain historical evidence. The strict Safe runner continues to reject that mismatch. Safe setup is no longer a dependency of the active demo.

The existing public-testnet demo uses **Pripo Mock USDC (`mUSDC`)**, a funded reserve, the `PRIPO:DEMO` market and a recorded one-unit long. [Current demo addresses and transaction evidence](../deployments/monad-testnet.json) remain the working public demo reference. Follow [the testnet runbook](testnet-staging.md) for this environment. Production still requires real USDC and reviewed production roles.

Public testnet supplies real Monad execution, timing and charged-fee measurements, including Mera P-256 if selected. The hosted fork supplies deployment, mainnet USDC integration, block/time manipulation, recovery scenarios and debugger evidence. Pyth-fed markets, Resolver and stale wind-down remain separate integration/implementation gates.

## Active single-account demo

| Component | Address |
| --- | --- |
| `PRIPO:DEMO` | `0xa4cB74124704886a950ca3240c730f9C103aE337` |
| Vault | `0xE50d9dF4e95669cA2165401f2756c8DEEa3B9ffd` |
| Factory | `0x8AEe7622d63609c68a94d1C16398a45446da6332` |
| USDC on the fork | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` |

`scripts/tenderly_demo.py` drives `script/TenderlyDemo.s.sol` from a committed, isolated source snapshot. Each stage simulates, checks the expected creations or exact calldata, journals submission, then verifies receipts and live state. The recorded instance's Admin RPC is refreshed from the authenticated API if its configured endpoint changes; credentials stay in ignored `.env`. Existing stage journals prevent accidental resubmission.

```sh
# Already completed on the current demo. Inspect existing receipts with --verify-only.
python3 scripts/tenderly_demo.py deploy --verify-only
python3 scripts/tenderly_demo.py fund --verify-only
python3 scripts/tenderly_demo.py market --verify-only
```

On an explicitly prepared new demo, the same stages default to simulation; `--execute` submits them. The runner requires the recorded hosted instance, RPC chain `999143`, the dedicated rehearsal account, and the recorded execution domain. Public mainnet/testnet RPCs are rejected. The Safe deployment records are retained under `reports/deployment/tenderly`; the active demo uses `reports/deployment/tenderly-demo`.

## Tenderly rehearsal plan

The hosted staging target is a **fresh Tenderly Virtual TestNet fork of Monad mainnet**, using mainnet USDC, mainnet Pyth and production state. Use fork-only balances against the actual USDC contract for the reserve, bonds and trader deposits. The mock-token public demo remains separate evidence.

Tenderly's [live network registry](https://api.tenderly.co/api/v1/supported-networks) was rechecked on **October 9 at 01:54:05 UTC**: Monad, chain **143**, is a mainnet with `virtual_testnet`, `monitoring`, `simulator` and `explorer` all enabled. `make tenderly-support` refreshes and saves the evidence in `reports/tenderly/network-support.json`. Its [Monad support announcement](https://tenderly.co/blog/tenderly-supports-monad-from-day-one/) also explicitly covers Virtual TestNets.

The RPC chain ID is **999143**. The observed EVM-domain mismatch means this environment does not establish typed-signature isolation. The active demo uses unsigned administrative RPC submissions from its rehearsal account. Production replay uses the correct target-chain configuration and actual production roles.

**Connected project:** account `monad-b15b6908b0`, project `project`. The environment is `b1348816-5fd8-46c6-9c73-97d2e30bba56`, forked October 9 from block `111799132`; state sync is off. Its sender has fork-only balances from explicit Admin RPC overrides. The separate project-metadata endpoint returned HTTP 403; environment access works independently. Alerts await a delivery channel and verification that this virtual network supports the selected alert targets.

The signed BTC payload was accepted by Pyth Core in `eth_call`, but its publish time was ahead of the fork clock, so the adapter freshness gate is **not verified**. Resolve the chain-domain issue and refork from fresh mainnet state before repeating the full rehearsal and live-Pyth checks. Tenderly receipt fees remain simulation evidence; Monad charged-gas measurements still require public testnet.

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

## Historical Safe rehearsal workflow

Supply `TENDERLY_ACCESS_KEY`, `TENDERLY_ACCOUNT_SLUG` and `TENDERLY_PROJECT_SLUG` in ignored `.env` to connect the granted account/project. An access key is created in [Tenderly's API token settings](https://docs.tenderly.co/platform/account/projects/api-tokens); keep it out of chat and Git. If an environment already exists, also provide its Admin RPC as `TENDERLY_RPC`; otherwise obtain that endpoint when creating the fresh environment. Set the existing on-call destination as `TENDERLY_DELIVERY_CHANNEL_ID` before binding alerts. The mainnet RPC and Pyth key already exist. Never publish the Admin RPC; it can mutate the environment.

With account/project access configured, inspect the project and existing environments first, then use the [Virtual Environments API](https://docs.tenderly.co/api-reference/virtual-environments/create-environment) or dashboard to create the fresh rehearsal. Inspect returned environment/instance metadata and confirm the chain-ID override before funding balances or deploying Safes.

```sh
python3 scripts/tenderly_stage.py project       # sanitized environment inventory
python3 scripts/tenderly_environment.py         # fresh block and creation plan only
python3 scripts/tenderly_environment.py --create
python3 scripts/tenderly_environment.py --verify-only
```

Creation writes an attempt journal before its API request. An existing journal or matching environment slug prevents another creation; reconcile an interrupted request using `--verify-only`. The runner checks parent 143, exact source block, RPC chain 999143 **and EVM CHAINID 999143**, compares USDC/Pyth/Safe code against pinned mainnet, and checks six-decimal USDC. It saves only the Admin RPC to ignored `.env`, with no RPC URLs in public reports. The creation request asks for 1,000 virtual MON for the synthetic sender; the live API returned a zero balance, so verify and fund it explicitly with the Admin RPC before deployment. Public explorer and bridges are disabled. This establishes fork/dependency provenance; signed Pyth verification and deployment are subsequent steps.

`scripts/deploy_tenderly.py` runs the stages `fund`, `safes`, `deploy`, `configure`, and `reserve`. It defaults to planning/simulation; `--execute` submits only to the verified isolated fork. `--verify-only` inspects an existing stage without resubmission. Source is extracted from a committed revision into ignored `reports/deployment/tenderly/source`, with copied dependency snapshots and recorded hashes. Every stage has a submission journal; a failed or interrupted stage requires reconciliation. The current `configure` journal records a reverted transaction and must not be blindly retried. Preserve prior environment records when preparing the fresh rehearsal.

Explicit HTTP validation/authentication rejections are recorded as `rejected`. After correcting the request or access, `--retry-rejected` preserves the rejected attempt, checks for an existing matching environment, and pins a fresh source block before resubmission. Timeouts or ambiguous server failures cannot use this path. The live API requires `explorer_config.contract_verification_visibility` even with the public explorer disabled; the request supplies `abi` explicitly. The published create-environment schema used `verification_visibility`, which the live endpoint rejected.

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
| Deployment and role wiring | Single-account Governor/Guardian/Treasury verified; direct account execution binds factory and backstop; reserve and market seed reconcile to USDC custody |
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

For production launch, regenerate against chain 143 and actual production addresses, verify enabled rules and destinations, and record a delivery test. Every newly created permissionless market must be enrolled; the three launch clones are not permanent coverage of the entire factory. Keep fork and production rule IDs separate. Workspace credentials, destination selection and deployment addresses currently block remote creation; no alert is described as live until created and verified.

## Week and release gate

The table records the original October 5 targets. Access arrived October 9; the elapsed Tuesday–Thursday targets are not completed milestones. Re-establish the remaining schedule after the hosted deployment and Resolver status are verified. Production release requires completed gates regardless of date.

| Day | Deliverable |
| --- | --- |
| Tue Oct 6 | Fresh Monad-mainnet Virtual TestNet; fork Safes; full deployment/governance and implemented recovery rehearsals; alerts bound and delivery tested where supported |
| Wed–Thu Oct 7–8 | Resolver/dispute/stale-wind-down implementation and regressions; fresh mainnet fork and full rerun |
| Thu night | Resolver green or select the fork-demo submission; mainnet then moves to judging week |
| Fri Oct 9 | Security checks and one-hour real Monad testnet measurement pass; real mainnet Safes/signers and USDC/MON capital ready |
| Sat Oct 10 | Replay reviewed scripts with production configuration if every gate is green; alerts live; reserve and bonds funded; three markets created; submit that night |

**Adapter-delay dependency:** the factory has an unmodified one-day approval delay. Saturday creation of Pyth markets needs the factory deployed and the adapter scheduled on Friday. If all infrastructure is first deployed Saturday, Pyth markets wait until Sunday. Oracle-less markets do not require Pyth approval. The Friday-infrastructure versus Saturday-only choice is pending; no mainnet approval delay is bypassed for the schedule.

The four planned public-testnet stress measurements are the first 64-match ADL call, bounded fallback completion, 128-position forced settlement, and a full payer-book funding checkpoint after a long gap. Also retain deployment/provider update receipts. Report RPC estimate, submitted gas limit, receipt gas used, effective gas price, transferred native value and isolated sender balance delta; derive the actual charged fee separately. Fork simulation numbers are not charged Monad fees. Check chain 10143 and identify the exact dependencies/collateral during this measurement pass. The existing mUSDC deployment can support clearly labelled demo measurements; native-USDC integration is verified separately on the fresh mainnet fork.

If Mera is selected, include real Monad testnet P-256 verification and an end-to-end passkey transaction in the same hour. A Tenderly result cannot satisfy that gate. Otherwise record the path as not selected.

By Friday the user supplies mainnet Safes/signers, **10,000 USDC reserve**, market/listing bonds and MON for gas. Three distinct Pyth markets additionally need **16,500 USDC** in seed/listing bonds; three oracle-less markets require **6,000 USDC** seed bonds. Trading collateral is separate. Safes, fee destinations and all policy inputs are reviewed in the production config. The mainnet RPC and Pyth key are already available; equity entitlements and feed selection remain market-specific gates.

Markets are immutable clones. The Thursday fallback is a fork demo, not a resolver-less mainnet launch. Preserve the compiler/build settings, commit, linked-library addresses, constructor arguments, role manifests, simulation evidence and actual receipts for the final replay and explorer verification.
