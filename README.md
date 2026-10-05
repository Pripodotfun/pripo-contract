# Pripo

Solidity foundation for permissionless perpetual markets with virtual pricing and USDC margin.

The repository contains the math foundation, an isolated USDC margin vault, and a market clone runtime for opens, increases, partial/full closes, funding, fees, referrals, operator policies, TWAP health, liquidation, and stale-oracle handling. The vault uses a UUPS proxy with a 48-hour upgrade delay and guardian veto.

Pending ADL is integrated with actual vault reservations, fixed entry/value schedules, funded one-wei rounding payments and a stable book capped at 128 positions. Explicit continuations and a delayed permissionless fallback complete greedy matches while funding is frozen. Only a fresh full-book eligibility scan can authorize forced settlement; terminal losses use profit haircuts and the protocol-capital waterfall. Funding now clamps to payer collateral above protected curve-loss collateral, with bounded per-side heaps and a binding-position freeze. Target-chain oracle/gas validation and verification of future resolver/parameter transitions remain launch work. The deterministic factory, Pyth/null adapters and batch fee sweeper are implemented. Exact `maxOpenable`, `liquidationPrice` and tagged `liquidationPriceInfo` views are implemented. Resolver settlement remains.

## Development

Requirements: Foundry, Python 3, and Git. Solidity **0.8.30** is pinned in `foundry.toml`; the local build uses the IR pipeline and targets **Cancun**. `MarketTrading`, `MarketLiquidation`, `MarketMargin`, `MarketAdl`, `MarketSettlement`, `MarketLens`, `MarketAccounting`, `MarketFundingCapacity`, `MarketMaintenance`, `FundingMath` and `MarkTwap` are linked libraries. Network-specific deployment settings will be verified with the Monad fork tests before deployment.

```sh
make deps       # install pinned dependency releases
make build      # compile, check contract sizes, and lint production sources
make test       # unit tests, fuzz tests, and funding invariants
make monad-preflight # read-only RPC, Pyth and native-USDC observations; uses ignored .env
make monad-fork  # opt-in tests at the preflight's pinned block; no broadcast
make monad-estimate-pyth # read-only Monad RPC estimates for captured signed provider updates
make deployment-dry-run # deploy/configure/trade rehearsal on pinned local forks; no broadcast
make ci         # 10,000 runs for each invariant; depth 50; size/lint/ABI checks
make abi        # regenerate JSON ABIs and TypeScript constants
make analyze    # Slither + Aderyn; requires both analyzers installed
```

Dependencies are [forge-std v1.11.0](https://github.com/foundry-rs/forge-std/releases/tag/v1.11.0) and [OpenZeppelin Contracts v5.4.0](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.4.0). They are installed into ignored `lib/` directories. Standard tests run locally without an RPC or private key. The opt-in [Monad fork checks](docs/monad-integration.md) use the ignored `.env` RPC and a pinned preflight report; they never broadcast transactions.

## Layout

| Path | Contents |
| --- | --- |
| `src/MarginVault.sol` | Token custody, balanced ledgers, reserves/deficits, fee allocation, operators, referrals, upgrade controls |
| `src/MarketFactory.sol` | Deterministic creation, bonded feeds, delayed adapter/implementation approvals |
| `src/adapters/` | Pyth Core pull updates and the canonical null source |
| `src/FeeSweeper.sol` | Bounded deficit repayment, reserve refill and gated treasury claims |
| `src/InsuranceBackstop.sol` | Global insurance policy and fixed per-market claim windows |
| `src/market/` | Shared market storage, trading, liquidation, accounting, and quote modules |
| `src/Market.sol` | Immutable clone implementation for isolated trading |
| `src/types/` | Shared WAD-denominated market, position, funding, and policy structs |
| `src/interfaces/` | Spec interfaces, events, and custom errors |
| `src/libraries/` | Pricing, risk, funding, fixed-point, and fee math |
| `script/DeployPripo.s.sol` | Contract deployment, final-role initialization and resumable Governor setup |
| `test/unit/` | Regression examples, boundary cases, and fuzz properties |
| `test/integration/` | Proxy/clone trading, oracle failures, callbacks, and market isolation |
| `test/invariant/` | Eight-actor funding arithmetic and actual-token custody invariants |
| `abi/` | Generated JSON interface ABIs |
| `packages/sdk/src/generated/abis.ts` | Generated TypeScript ABI constants |
| `docs/implementation-notes.md` | Numerical conventions and integration work |

## Current verification scope

The funding harness isolates numerical accounting. The market invariant uses an ERC-1967 vault proxy, an EIP-1167 market clone, and six-decimal mock USDC with actual ERC-20 transfers. It checks custody equality, curve conservation, position/entry-cost/weighted-index totals, initial margin after opens, pending funding, sweeps, and a complete unwind. A third suite checks capital allocation across eight terminal-market stubs: signed cash equality, terminal-only deficits, fixed-floor admission, repayment ordering and treasury gates. A fourth suite exercises liquidation, paired ADL and terminal recovery from explicitly injected historical debt. A fifth checks payer funding capacity, heap minima, freeze ownership and cash backing across two production markets without liquidations. All five run 10,000 sequences of depth 50 under the CI profile. Integration tests cover profit haircuts, signed clearing netting, winners withdrawing before debtors, permanent terminal state and full-book gas. Deficit-inclusive accounting equality does not establish full cash backing.

Production pending ADL tests cover both sides, random continuation boundaries, realizable relief, stable cursors under winner closes, multiple reservations, margin replacement, funding freezes and terminal cleanup. The liquidation invariant reconciles each reservation with the vault and checks frozen schedules and funding. Independent model properties retain longer random chunk schedules and arbitrary finite eligibility changes. See [runtime validation](docs/validation.md#pending-adl-runtime-integration) for the tested scope and remaining deployment work.

`marketAbi`, `marginVaultAbi`, `marketFactoryAbi`, `pythAdapterAbi`, `nullAdapterAbi` and `feeSweeperAbi` describe implemented contracts. `plannedMarketAbi` describes the remaining Phase 1 surface and must not be used as proof that those methods exist today. Operator overloads carry market proofs, and all vault settlement credits have named source accounts. `@pripo/sdk` currently exports ABI constants; transaction preparation and signing are later work.

Factory tests cover atomic creation/rollback, fixed launch caps, reserve admission, feed escrow, delayed approvals and callback rejection. Oracle tests cover both an ABI-compatible provider mock and authenticated signed updates against the real Monad provider on pinned forks. Testnet execution and charged-fee measurements remain deployment gates.

The [deployment runbook](docs/deployment.md) covers the passing 19-contract creation rehearsal, final Governor setup, signed-price market lifecycle, testnet inputs and remaining mainnet gates. The rehearsal broadcasts no transactions; live deployment and Monad-native charged-fee measurements remain pending.

See [implementation notes](docs/implementation-notes.md), [static-analysis triage](docs/validation.md), and the [protocol specification](Pripo-Perp%20protocol%20spec%20%E2%80%94%20permissionless%20LP-free%20markets%20on%20Monad%20%281%29.md).

The funding-backing invariant uses two production markets with no liquidations or recapitalization, verifies each payer's capacity and both heap minima after every action, and withdraws full free entitlements without clamping withdrawals to available cash. Each sequence ends with a receiver-first unwind. Existing ADL/terminal stress fixtures now explicitly inject historical debt through test-only contracts; production no longer creates that debt through unlimited funding. See [implementation notes](docs/implementation-notes.md#payer-funded-capacity-and-recovery) for the capacity predicate and partial-close fee guard.
