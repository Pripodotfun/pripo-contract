# Pripo

Solidity foundation for permissionless perpetual markets with virtual pricing and USDC margin.

The first development milestone contains shared types and contract interfaces, curve fills, impact-margin and cap calculations, funding accounting, fee math, Solidity tests, and generated SDK ABI constants. The vault and market runtime are the next milestone.

## Development

Requirements: Foundry, Python 3, and Git. Solidity **0.8.30** is pinned in `foundry.toml`; the local math/test build targets **Cancun**. Network-specific deployment settings will be verified with the Monad fork tests before deployment.

```sh
make deps       # install pinned dependency releases
make build      # compile and lint production sources
make test       # unit tests, fuzz tests, and funding invariants
make ci         # 10,000 fuzz/invariant runs; invariant depth 50; check ABI exports
make abi        # regenerate JSON ABIs and TypeScript constants
make analyze    # Slither + Aderyn; requires both analyzers installed
```

Dependencies are [forge-std v1.11.0](https://github.com/foundry-rs/forge-std/releases/tag/v1.11.0) and [OpenZeppelin Contracts v5.4.0](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.4.0). They are installed into ignored `lib/` directories. Tests run locally without an RPC or private key.

## Layout

| Path | Contents |
| --- | --- |
| `src/types/` | Shared WAD-denominated market, position, funding, and policy structs |
| `src/interfaces/` | Spec interfaces, events, and custom errors |
| `src/libraries/` | Pricing, risk, funding, fixed-point, and fee math |
| `test/unit/` | Regression examples, boundary cases, and fuzz properties |
| `test/invariant/` | Stateful funding-accounting tests with eight actors |
| `abi/` | Generated JSON interface ABIs |
| `packages/sdk/src/generated/abis.ts` | Generated TypeScript ABI constants |
| `docs/implementation-notes.md` | Numerical conventions and integration work |

## Current verification scope

The funding harness verifies cash conservation, weighted index sums, signed obligations, rounding, and insurance sweeps across arbitrary settlement ordering and position-size changes. It uses synthetic signed margin to isolate the accounting libraries. The next invariant suite must exercise actual USDC custody, isolated position debt, authorization, liquidation, and the bad-debt waterfall through `MarginVault` and `Market`.

The interface exports currently follow the spec's public surface. Vault settlement and operator-proof transport need concrete integration signatures before the trading ABI is frozen. `@pripo/sdk` currently exports ABI constants; transaction preparation and signing are later work.

See [implementation notes](docs/implementation-notes.md), [static-analysis triage](docs/validation.md), and the [protocol specification](Pripo-Perp%20protocol%20spec%20%E2%80%94%20permissionless%20LP-free%20markets%20on%20Monad%20%281%29.md).
