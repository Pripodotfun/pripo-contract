# Pripo

Solidity foundation for permissionless perpetual markets with virtual pricing and USDC margin.

The repository contains the math foundation, an isolated USDC margin vault, and a market clone runtime for opens, increases, partial/full closes, funding, fees, referrals, operator policies, TWAP health, liquidation, and stale-oracle handling. The vault uses a UUPS proxy with a 48-hour upgrade delay and guardian veto.

This is the reserve and terminal-capital custody milestone. The vault now tracks prefunded reserves, market admission budgets, terminal deficits, ordered fee repayment, and treasury/opening gates. Liquidations and voluntary full closes still cover debt from market insurance and the capped global backstop, then revert on uncovered debt. Paired ADL and the whole-book settlement engine must be integrated with the new custody primitives before those paths can finish terminal settlement. Factory/adapters, exact remaining risk views, resolver settlement, and the cash-backing deployment gate also remain.

## Development

Requirements: Foundry, Python 3, and Git. Solidity **0.8.30** is pinned in `foundry.toml`; the local build uses the IR pipeline and targets **Cancun**. `MarketTrading`, `MarketLiquidation`, `MarketLens`, `MarketAccounting`, `FundingMath` and `MarkTwap` are linked libraries. Network-specific deployment settings will be verified with the Monad fork tests before deployment.

```sh
make deps       # install pinned dependency releases
make build      # compile, check contract sizes, and lint production sources
make test       # unit tests, fuzz tests, and funding invariants
make ci         # 10,000 runs for each invariant; depth 50; size/lint/ABI checks
make abi        # regenerate JSON ABIs and TypeScript constants
make analyze    # Slither + Aderyn; requires both analyzers installed
```

Dependencies are [forge-std v1.11.0](https://github.com/foundry-rs/forge-std/releases/tag/v1.11.0) and [OpenZeppelin Contracts v5.4.0](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.4.0). They are installed into ignored `lib/` directories. Tests run locally without an RPC or private key.

## Layout

| Path | Contents |
| --- | --- |
| `src/MarginVault.sol` | Token custody, balanced ledgers, reserves/deficits, fee allocation, operators, referrals, upgrade controls |
| `src/InsuranceBackstop.sol` | Global insurance policy and fixed per-market claim windows |
| `src/market/` | Shared market storage, trading, liquidation, accounting, and quote modules |
| `src/Market.sol` | Immutable clone implementation for isolated trading |
| `src/types/` | Shared WAD-denominated market, position, funding, and policy structs |
| `src/interfaces/` | Spec interfaces, events, and custom errors |
| `src/libraries/` | Pricing, risk, funding, fixed-point, and fee math |
| `test/unit/` | Regression examples, boundary cases, and fuzz properties |
| `test/integration/` | Proxy/clone trading, oracle failures, callbacks, and market isolation |
| `test/invariant/` | Eight-actor funding arithmetic and actual-token custody invariants |
| `abi/` | Generated JSON interface ABIs |
| `packages/sdk/src/generated/abis.ts` | Generated TypeScript ABI constants |
| `docs/implementation-notes.md` | Numerical conventions and integration work |

## Current verification scope

The funding harness isolates numerical accounting. The market invariant uses an ERC-1967 vault proxy, an EIP-1167 market clone, and six-decimal mock USDC with actual ERC-20 transfers. It checks custody equality, curve conservation, position/entry-cost/weighted-index totals, initial margin after opens, pending funding, sweeps, and a complete unwind. A third suite checks capital allocation across eight terminal-market stubs: signed cash equality, terminal-only deficits, aggregate admission budgets, repayment ordering and treasury gates. All three run 10,000 sequences of depth 50 under the CI profile. The stubs model the trusted settlement boundary; they do not validate whole-book pricing or haircuts.

`marketAbi` and `marginVaultAbi` describe the implemented contracts. `plannedMarketAbi` describes the remaining Phase 1 surface and must not be used as proof that those methods exist today. Operator overloads carry market proofs, and all vault settlement credits have named source accounts. `@pripo/sdk` currently exports ABI constants; transaction preparation and signing are later work.

See [implementation notes](docs/implementation-notes.md), [static-analysis triage](docs/validation.md), and the [protocol specification](Pripo-Perp%20protocol%20spec%20%E2%80%94%20permissionless%20LP-free%20markets%20on%20Monad%20%281%29.md).
