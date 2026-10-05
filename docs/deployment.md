# Deployment rehearsal and testnet rollout

## Current state

Deployment tooling is implemented. The October 5 rehearsal created **19 contracts** on a local Monad mainnet fork: 11 linked libraries, the vault implementation and initialized ERC-1967 proxy, market implementation, two adapters, backstop, sweeper and factory. No transaction was submitted to a public network.

The creation simulation estimated **44,622,346 gas**, including Foundry's default gas multiplier. This is a simulated transaction-limit budget, not a Monad-native execution measurement or a charged fee. Individual limits are retained in `reports/deployment/rehearsal.json`; actual submitted limits and charged gas/fees remain null. Foundry's generic `ETH` label refers to the target network's native currency in this output.

The lifecycle regression uses block **110131422** for creation and Governor setup, then block **110731422** for signed-price trading. Their real timestamps are **181,260 seconds** apart. Only the local protocol deployments persist across forks; USDC and Pyth use the real state at each block. It verifies delayed adapter activation, rejection before reserve funding, a 10,000-USDC reserve contribution, 500-USDC feed listing, 5,000-USDC market seed, market creation with a signed BTC update, open/close, withdrawal, fee sweeping and vault cash reconciliation. Test balances and roles are synthetic.

## Repeat the rehearsal

With the existing archive RPC, Pyth capture and dependencies:

```sh
make deployment-dry-run
```

The runner checks chain ID and pinned block hashes, runs `DeployPripo`, then the full lifecycle regression. It has no signing or broadcast option. Config, address/code-hash manifest, ordered Governor calldata, redacted logs and the result summary go in ignored `reports/deployment/`. Foundry also writes its unsigned transaction plan to ignored `broadcast/DeployPripo.s.sol/143/dry-run/`. The manifest records simulated addresses; it does not establish a live deployment. A failed rerun leaves the summary marked incomplete.

## Prepare testnet inputs

Copy `config/deploy-testnet.example.json` to `reports/deployment/testnet-config.json`. Replace every zero address with the reviewed testnet dependency or final role address. Set `MONAD_TESTNET_RPC`, `DEPLOYER`, `DEPLOY_CONFIG` and `DEPLOY_OUTPUT` in ignored `.env` as shown in `.env.example`. Signing uses a keystore or hardware wallet; these scripts do not read private keys.

- Chain ID: **10143**. The scripts reject a mismatched network, missing code, non-six-decimal collateral, zero roles and oracle timing outside the current 3-second/300-ms configuration.
- USDC: verify against [Circle's registry](https://developers.circle.com/stablecoins/usdc-contract-addresses), which currently lists `0x534b2f3A21130d7a60830c2Df862319e593943A3` for Monad testnet, then cross-check code and token views on the target RPC.
- Pyth: select upgraded **Core** from [Pyth's contract registry](https://docs.pyth.network/price-feeds/core/upgrade/contracts). Its testnet row differs from mainnet. Verify a current signed update against that exact testnet contract before rollout. The mainnet rehearsal does not validate this testnet pairing.
- Roles: supply final Governor, Guardian and Treasury addresses. Governor is fixed by the current initializer; there is no role-transfer method. No Council role exists in the current implementation.
- `slashToReserve`: the template uses `true` for rehearsal. Explicitly review this immutable policy choice; `false` directs slashed listing bonds to the global backstop.

The dependency checks establish code presence and ABI compatibility, not token/provider authenticity. Address provenance and signed-update verification remain necessary. The script initializes the vault proxy atomically, and neither the deployment script nor a separate deployer receives an administrative role. The Governor retains its initializer-granted registrar permission.

## Deployment stages

The following commands simulate only. Set the shell's `DEPLOYER` to the same public address as `.env` so Foundry's library transaction sender matches the core contract sender:

```sh
export DEPLOYER=0xYOUR_PUBLIC_DEPLOYER_ADDRESS
forge script script/DeployPripo.s.sol:DeployPripo --rpc-url monad_testnet --sender "$DEPLOYER"
```

Foundry links the library dependency graph and records the creation sequence. Review the config, manifest, transaction plan and individual gas limits before live execution. Broadcasting requires a separately authorized invocation with `--broadcast` and the selected wallet, as described in [Foundry's deployment documentation](https://getfoundry.sh/forge/deploying). Preserve the transaction plan and receipts. If interrupted, reconcile receipts and resume the existing plan with Foundry's `--resume`; rerunning creation from scratch would deploy another set of core contracts.

After successful creation, the Governor executes these zero-value calls in order:

1. Vault `setBackstopController(backstop)`.
2. Vault `setRegistrar(factory, true)`.
3. Factory `scheduleAdapter(pythAdapter)`.

The manifest's `governanceTargets`, `governanceValues` and `governanceCalldata` arrays contain the exact calls for a multisig. For an EOA Governor, simulate:

```sh
forge script script/DeployPripo.s.sol:ConfigurePripo --sig 'configure()' --rpc-url monad_testnet
```

`ConfigurePripo` has no linked library deployments. It validates recorded runtimes, proxy implementation, dependency bindings and roles. It skips completed setup calls and preserves an existing adapter deadline. A conflicting backstop rejects before any setup transaction is recorded. The raw multisig bundle is for initial setup: after partial execution, omit completed calls, especially the one-time backstop binding and already-pending adapter schedule.

After the full one-day delay, anyone can simulate and subsequently execute activation:

```sh
forge script script/DeployPripo.s.sol:ConfigurePripo --sig 'activate()' --rpc-url monad_testnet
```

Fund the reserve using USDC approval followed by `fundProtocolReserve(10000000000)` before admitting the first market. Funding is a separate, irrevocable capital contribution; deployment does not transfer tokens. Feed listing and external market creation require another 500 USDC and 5,000 USDC respectively. Refresh oracle updates at execution time. Confirm the vault roles, factory registrar, backstop binding, adapter approval and reserve ledger from live state before opening a market.

## Remaining launch work

Testnet still needs a funded signer, final roles, the testnet RPC and verified dependencies. Record estimated gas, submitted limits and charged fees for deployment, full-book ADL and settlement on Monad itself. Explorer source verification must include the exact library addresses and constructor arguments from the transaction plan.

Mainnet remains gated on resolver settlement/wind-down, the equity feed entitlement/mapping decision, target-chain recovery measurements and the final security review. Markets are immutable clones; deploying now does not give existing markets future resolver functionality. The 10,000-USDC mainnet reserve is required before the first market opens.
