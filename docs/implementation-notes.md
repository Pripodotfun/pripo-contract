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

`scripts/export_abis.py` reads compiler artifacts and writes nine deterministic JSON ABIs plus TypeScript `as const` exports. Run `make abi` after changing interfaces. The `--check` mode compares exports with the current build without modifying files.

`Market` implements `IMarketCore`. The extended `IMarket` interface describes future liquidation and resolver methods; there are no placeholder implementations. SDK `marketAbi` and `marginVaultAbi` come from the concrete contracts. Deployment addresses and transaction-sending SDK methods remain future work.

## Vault integration

- The vault owns the authoritative per-market ledger. `settlePnl` balances locked collateral against signed clearing; `settleFunding` balances it against the signed funding pool. `chargeFee`, insurance funding/coverage, funding sweeps and claims have explicit counter-entries. No global accounting counter is written during trading.
- `locked[user][market]` is signed. The public `Position.margin` is its positive part, and `positionDebt(user)` is its negative part. Pending funding remains separate until settled. Funding alone can create debt without closing a position or consuming the user's other free collateral. A full close clears any debt against this market's insurance and emits `BadDebt`.
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
- `FundingMath.accrue` and `MarkTwap` are linked library calls. Their addresses are fixed in the implementation bytecode and must be verified alongside the market implementation at deployment. Solidity 0.8.30 uses the IR compiler to keep the runtime within the EIP-170 limit. Run `make build` to enforce the size gate as the implementation grows.

## Next milestone

Implement liquidation and its penalty split, partial liquidation completion, backstop caps, and ADL before enabling production trading. Current insurance-only debt coverage reverts if the sub-fund is exhausted; it does not yet satisfy the full waterfall/payout guarantee. Add the liquidation attack scenarios, `liquidationPrice` and `maxOpenable`, then expand custody invariants to the full waterfall. Factory/adapters, resolver settlement/haircuts, governance parameter changes and Monad fork tests follow. The runtime has not been deployed.

The original funding harness remains useful for extreme arithmetic and settlement-order cases. It complements the actual-token vault/market invariant; neither suite currently proves liquidation or resolver settlement behavior.
