# Contract foundation

## Numerical conventions

- Token deposits and withdrawals use raw six-decimal USDC; internal quote balances use WAD. `FixedPointMath.usdcToWad` scales by `10^12`.
- `AmmState.k` is the unscaled product of WAD base and quote reserves. Its unit is WAD squared. Seeds reject products that exceed `uint256`.
- Each curve endpoint uses `ceil(k / baseReserve)`. Longs pay the difference between endpoint quote reserves; shorts receive that difference. PnL and entry cost use exact quote amounts, never a rounded average price. Zero-size, reserve-exhausting, malformed-reserve, and zero-quote trades revert.
- Partial closes allocate entry cost by floor division. The final close removes all remaining entry cost, so the allocated costs sum exactly to the original cost.
- Worst long proceeds round down; worst short buyback costs round up. Initial margin takes the maximum of the leverage minimum and full impact minimum, including the maintenance buffer. Fee payment is separate.
- Side-cap basis points are derived with an exact integer inequality and binary search. The result is 128/557/1010/1715 bps at 20x/5x/3x/2x. Depth uses the applied cap and rounds up. The factory will additionally check quote-cap coverage after integer reserve seeding.
- Funding indexes use quote per base in WAD. Weighted obligations and remainders retain WAD-squared precision. The symmetric stored product domain is bounded by `int256.max`; overflows revert.
- Funding settlement uses a signed ceiling: payer debits round up and receiver credits round down in absolute amount. `roundingHi` tracks the difference exactly.
- `fundingPool` is signed. The exact surplus identity includes pending obligations, accrual remainder, settlement rounding, and prior sweeps. Sweeping may make the pool negative when accrued surplus has not yet been collected from payers.
- Taker fees round up; creator, insurance, and referral shares round down; protocol receives split dust and the unused referral share. Phase 1 has no skew premium. The skew-reducing fee discount is implemented.

## Public artifacts

`scripts/export_abis.py` reads the compiler's interface artifacts and writes six deterministic JSON ABIs plus TypeScript `as const` exports. Run `make abi` after changing interfaces. The `--check` mode compares exports with the current build without modifying files.

Interfaces preserve the current specification. There are no placeholder contract implementations, deployment addresses, or transaction-sending SDK methods in this milestone.

## Next milestone: vault and one market

1. Implement explicit, balanced vault transitions for PnL, funding, fees, insurance, and claims. The spec's generic `settle(user, delta)` needs a concrete source-account model; market authorization alone must not allow an unbacked credit.
2. Choose and implement per-position funding-debt representation. `Position.margin` is unsigned, while an accrued funding debit can exceed it. `FundingMath.settle` returns the debit; it does not underflow margin or decide how debt is covered.
3. Carry allowed-market Merkle proofs and an open/close action discriminator through operator authorization. The current spec ABI does not carry either. Enforce expiry, cumulative consumption, revocation, market scope, and `canClose` atomically.
4. Wire accrual to cached oracle/reference observations so the documented close path can execute without an oracle call. Quote views and transaction simulation must use the same pricing and fee functions.
5. Implement one isolated market and a mock USDC vault integration, then run the full handler-based invariants before moving to the factory and external adapters.

The current funding harness covers numerical accounting only. Its signed synthetic margins are a test mechanism, not the vault's collateral or liquidation policy.
