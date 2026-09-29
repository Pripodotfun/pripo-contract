# Contract implementation

## Numerical conventions

- Token deposits and withdrawals use raw six-decimal USDC; internal quote balances use WAD. `FixedPointMath.usdcToWad` scales by `10^12`.
- `AmmState.k` is the unscaled product of WAD base and quote reserves. Its unit is WAD squared. Seeds reject products that exceed `uint256`.
- Each curve endpoint uses `ceil(k / baseReserve)`. Longs pay the difference between endpoint quote reserves; shorts receive that difference. PnL and entry cost use exact quote amounts, never a rounded average price. Zero-size, reserve-exhausting and malformed-reserve trades revert. Zero-quote opens revert; closes and hypothetical valuations allow a zero quote amount so dust can exit.
- Partial closes allocate entry cost by floor division. The final close removes all remaining entry cost, so the allocated costs sum exactly to the original cost.
- Worst long proceeds round down; worst short buyback costs round up. Initial margin takes the maximum of the leverage minimum and full impact minimum, including the maintenance buffer. Fee payment is separate.
- Side-cap basis points are derived with an exact integer inequality and binary search. The result is 128/557/1010/1715 bps at 20x/5x/3x/2x. Depth uses the applied cap and rounds up. The factory will additionally check quote-cap coverage after integer reserve seeding.
- Funding indexes use quote per base in WAD. Weighted obligations and remainders retain WAD-squared precision. The symmetric stored product domain is bounded by `int256.max`; overflows revert.
- Funding settlement uses a signed ceiling: payer debits round up and receiver credits round down in absolute amount. `roundingHi` tracks the difference exactly.
- `fundingPool` is signed. The exact surplus identity includes pending obligations, accrual remainder, settlement rounding, and prior sweeps. Sweeping may make the pool negative when accrued surplus has not yet been collected from payers.
- Taker fees round up; creator, insurance, and referral shares round down; protocol receives split dust and the unused referral share. Phase 1 has no skew premium. The skew-reducing fee discount is implemented.

## Public artifacts

`scripts/export_abis.py` reads compiler artifacts and writes eleven deterministic JSON ABIs plus TypeScript `as const` exports. Run `make abi` after changing interfaces. The `--check` mode compares exports with the current build without modifying files.

`Market` implements `IMarketCore`. The extended `IMarket` interface describes future exact risk views and resolver methods; there are no placeholder implementations. SDK `marketAbi` and `marginVaultAbi` come from the concrete contracts. Deployment addresses and transaction-sending SDK methods remain future work.

## Vault integration

- The vault owns the authoritative per-market ledger. `settlePnl` balances locked collateral against signed clearing; `settleFunding` balances it against the signed funding pool. `chargeFee`, insurance funding/coverage, funding sweeps and claims have explicit counter-entries. No global accounting counter is written during trading.
- `locked[user][market]` is signed. The public `Position.margin` is its positive part, and `positionDebt(user)` is its negative part. Pending funding remains separate until settled. Funding alone can create debt without closing a position or consuming the user's other free collateral. A full close covers debt from this market's insurance followed by the capped global backstop, emitting `BadDebt` separately for each source. Any uncovered remainder currently reverts atomically.
- Balanced accounting does not authenticate arbitrary market code. Registration is restricted to the governor's approved registrars; those registrars must deploy only the reviewed implementation. Registration is permanent to preserve exit access.
- Deposits/withdrawals use raw six-decimal USDC. Fee claims transfer only whole raw-token units and leave dust in the originating owed account. Direct token donations are outside the protocol transition model: they create unallocated excess cash and count toward the deposit cap; no sweep of that excess is implemented.
- A clone's registrar must register, fund, and initialize it atomically. The implementation itself cannot initialize; the clone permits only its recorded registrar, once. The vault must be deployed with its initializer encoded in the ERC-1967 proxy constructor.
- Vault upgrades require governor scheduling, the same implementation and initializer-data hash, and a 48-hour delay. Guardian or governor can cancel. Market pause does not affect vault withdrawals. Risk-parameter timelocks and cap changes are still future governance work.

## Operators and quotes

- Operator expiry is a **block number**, exclusive: `block.number >= expiry` rejects. `setOperator` replaces the policy and resets consumption. Both opens and closes consume actual curve quote notional; closing additionally requires `canClose`. Operators cannot add/remove margin or withdraw.
- Market leaves use `keccak256(bytes.concat(keccak256(abi.encode(market))))`, with sorted Merkle pairs. The five-argument `openFor`/`closeFor` overloads carry the proof. The four-argument overloads use an empty proof, suitable for an unrestricted root or a single-leaf tree.
- `quoteOpen(size)` quotes for `msg.sender`; operators should use `quoteOpenFor(user,size)`. Returned margin is the **additional** free collateral required after simulated funding settlement. Fees are additional. Opens increase an existing position on the same side; closing to zero is required before changing sides.
- `quoteClose` returns the closed portion's curve PnL and fee, but funding owed for the entire position, matching execution. Partial closes retain collateral; `removeMargin` checks both worst-case initial margin and reference equity. A full close removes all remaining entry cost and releases all positive collateral.
- A buy's limit is a maximum price and a sell's limit is a minimum. Use transaction simulation to check authorization, balance, current oracle data and status; numerical quote views do not perform external oracle updates or consume a policy.

## Oracle and TWAP integration

- Funding accrues against the cached observation before a fresh price is installed. For external markets it stops at the first degraded block, so a later fresh update does not retroactively charge the outage. Oracle-less funding uses mark TWAP and skew.
- Opens read the primary source and can fall back to a configured secondary. `poke` attempts reads without a paid update; fresh observations can restore Active status. `remark(bytes)` supports paid updates. A guardian pause survives all price refreshes; only the governor can resume opens.
- **Closes do not call an adapter.** Their update bytes are ignored for ABI compatibility and nonzero native value is rejected. They can transition the market to Degraded from cached age. A successful primary/secondary observation on a subsequent `poke` or `remark` restores activity.
- TWAP stores cumulative mark-by-block integrals in a 601-slot ring. Same-block trades replace the final mark for the next interval and do not receive time weight immediately. Before one block has elapsed, the initial mark is the reference. A binary search finds the observation bracketing the 300- or 600-block window; sparse intervals are interpolated.
- `MarketTrading`, `MarketLiquidation`, `MarketLens`, `MarketAccounting`, `FundingMath.accrue` and `MarkTwap` use linked library calls. Their addresses are fixed in the implementation bytecode and must be verified alongside the market implementation at deployment. Solidity 0.8.30 uses the IR compiler to keep the runtime within the EIP-170 limit. Run `make build` to enforce the size gate as the implementation grows.

## Backstop and module foundations

- `InsuranceBackstop` holds policy and claim budgets; all USDC and the global WAD balance remain in the vault. Anyone can irrevocably contribute from their free balance. The governor binds the controller once; replacing it requires a delayed vault upgrade.
- Each market snapshots 20% (external index) or 10% (oracle-less) of the available global balance on its first claim in a 288,000-block window. Subsequent claims subtract from that fixed budget. Deposits cannot reset it; another market's claims can reduce available cash. A new window starts at the next claim after expiry. These are fixed windows, not rolling windows or wall-clock days.
- Permissionless `topUp` moves insurance above `ceil(2 × current oiCap / multiplier)` into the backstop. Launch OI caps still apply and no backstop allocation is counted toward opening capacity.
- Vault `coverBadDebt` balances insurance and capped backstop credits against negative locked collateral and returns any remainder. Only trusted market implementations may call it; they must handle that remainder atomically. Both liquidation and voluntary full close use this coverage path.
- Penalty accounting debits at most positive locked collateral, credits 40% to the caller's free balance (rounded down), and the rest to insurance. An insolvent account cannot generate insurance-funded keeper rewards. The ADL transfer primitive can debit only same-market locked collateral and cannot overpay the debtor's deficit; selection and profit eligibility remain unimplemented.
- Market state now lives at the fixed `pripo.market.storage.v1` namespace shared by immutable linked modules. This changes the layout of undeployed market implementations and is not a migration for existing clones. The vault additions are append-only. All external market mutations retain the market's reentrancy guard; modules cannot replace their linked targets at runtime.

## Liquidation integration

- Anyone may call `liquidate(user, update)`, including during a guardian pause. It accrues cached funding, refreshes the external index when not degraded, settles the position's funding, then checks maintenance health. Healthy and empty positions revert. Non-degraded external markets require a fresh primary/secondary observation; supplied update fees are forwarded to the primary.
- Degraded liquidation uses the 600-block TWAP without calling an adapter and rejects native value. A separate successful `remark` or `poke` can restore oracle operation. Oracle-less liquidation also rejects native value.
- The first close is 50% above 50,000 quote notional for external markets or 10,000 for oracle-less markets, otherwise 100%. Threshold notional uses the fresh index, or TWAP in degraded/oracle-less mode. Fractional quote wei above the boundary count as above it. Degraded mode closes at most half per call, except the final one base wei, which cannot be halved.
- A normal partial must leave maintenance equity after its penalty; otherwise it closes the rest in the same transaction. Degraded mode deliberately retains its half-size limit even if another call is needed. This is an explicit exception to the general completeness invariant and follows the spec's degraded-mode rule.
- Every fill uses actual curve reserves. Entry-cost reductions, funding weights, aggregate sizes and clearing use the same transition as voluntary close. Partial collateral stays locked. Full close releases any positive balance and deletes the position.
- The 150-bps penalty is calculated once on total actual curve quote closed, rounded up, and capped to positive post-PnL collateral. Keeper share rounds down to 40%; insurance receives the rest. Liquidation does not add the ordinary taker fee. `Liquidated.badDebt` reports the positive amount covered, while `BadDebt.coveredBy` identifies insurance (0) or backstop (1).
- If insurance and available backstop coverage are insufficient, `UncoveredBadDebt(remaining)` rolls back fills, funding, penalties and claim-budget consumption. This is an incomplete development path pending ADL/terminal settlement; it does not implement the updated terminal settlement and protocol-recapitalization policy.

## Accepted target policy and next milestone

The updated protocol spec resolves the ADL and terminal-shortfall choices:

- ADL pairs equal opposite sizes off the curve at `p_adl`, with no reserve movement. Paired PnL and entry-cost removal preserve clearing. Submitted candidates are checked for eligibility and score ordering; the keeper uses the indexer for ranking.
- Insufficient eligible size triggers whole-market settlement at the 300-block mark TWAP. After applying remaining market insurance, funding comes from losing collateral, open-profit haircuts, this market's unclaimed creator/protocol fees, the global backstop without its live daily cap, then a protocol reserve. Only the remaining gap becomes protocol deficit on a `Settled` market.
- The protocol reserve target is `max(10_000e18, Σ ceil(oiCap × fundingCapPerPeriod × 8 / WAD))`, using admitted exposure ceilings. It requires initial cash funding. Protocol allocations repay terminal deficits first, refill reserve second, and distribute to treasury last. Every successful treasury sweep must leave the reserve floor intact and aggregate deficit zero.
- In Phase 1 any terminal deficit globally pauses opens. The Guardian must arrange and verify recapitalization within 24 hours. Deficit repayment does not reopen a settled market. `Impaired` and the advanced-profit claims cap remain Phase 2.

**Implementation status:** none of the paired ADL, terminal fee absorption, backstop cap waiver, protocol reserve, terminal deficit, global pause/repayment or claims machinery is implemented yet. Current `Market.liquidate(user, update)` and voluntary full close still revert with `UncoveredBadDebt` after ordinary insurance/capped-backstop exhaustion. The existing locked-collateral ADL transfer primitive is not an implementation of the newly accepted paired-close design. Runtime ABIs remain generated from actual contracts; spec target selectors are not advertised as deployed functionality.

**Remaining design/verification gates:**

1. A recorded protocol deficit is not a cash asset. After protocol capital is exhausted, deficit booking can leave nominal user balances larger than available cash. The eight-period buffer is a sizing assumption; a cash-backing guarantee needs enforceable funding-lag/notional limits or additional prefunded coverage. Guardian top-up promises do not close that proof.
2. Atomic whole-market settlement needs an enumerable book with a tested worst-case position bound. An omitted/empty caller-supplied candidate list is not proof that eligible opposite positions are exhausted; the terminal trigger must be checked against actual book availability.
3. Specify paired-price rounding, zero/negative-margin ranking, partial-position collateral allocation, and terminal PnL/haircut/reserve-reset counter-entries before extending the exact curve and funding invariants. New cash sources cannot be counted twice or borrowed from unrelated user balances.
4. The Phase 2 advanced-profit cap must reserve capacity across recipients and include positive funding receipts, so receivers cannot bypass it by settling and withdrawing before a close.

Next implementation work is paired ADL, bounded forced settlement, reserve/deficit custody and fee allocation, and invariant coverage for all terminal sources. Exact remaining risk views (`liquidationPrice`, `maxOpenable`), factory/adapters, resolver governance integration, parameter changes and Monad fork tests follow. The runtime has not been deployed.

The existing funding and real-token invariant suites complement the liquidation integration/fuzz tests. They do not yet generate paired ADL, protocol reserve or terminal settlement transitions.
